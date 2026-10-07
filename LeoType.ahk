#Requires AutoHotkey v2.0
#SingleInstance Force

; Set custom hacker icon for the system tray
if FileExist(A_ScriptDir "\LeoType.ico") {
    TraySetIcon(A_ScriptDir "\LeoType.ico")
}

; Configure System Tray Left-Click Behavior
A_IconTip := "LeoType"
OnMessage(0x0404, AH_TrayIconInteraction)

; Tray menu entries (inserted above the standard items)
A_TrayMenu.Insert("1&", "Show / Hide LeoType", (*) => ToggleUiVisibility())
A_TrayMenu.Insert("2&", "Reset Position", (*) => PlaceDefaultPosition())
A_TrayMenu.Insert("3&")

; Prevent freezing and DPI issues
DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")
DllCall("user32\EnableNonClientDpiScaling", "ptr", A_ScriptHwnd)

CoordMode "Mouse", "Screen"

IniFile := A_ScriptDir "\panel_pos.ini"
PanelWidth := 260

; Delay between paste and Enter (milliseconds)
global PasteEnterDelay := 2000

; Toolbar switches to compact layout below these window widths
global FullMinWidth := 520        ; alpha controls shown
global FullMinWidthNoAlpha := 360 ; alpha controls hidden

; Whether the [ Inject Toolbar ] row is shown on the LeoType panel (saved in ini)
global InjectVisible := (IniRead(IniFile, "UI", "InjectVisible", "1") != "0")
global PanelHeight := InjectVisible ? 155 : 122

; Core Engine State Management Variables
global IsTypingActive := false
global CurrentCharIndex := 0
global TextToType := ""
global SpeedMultiplier := 1.0
global TypoCount := 0
global SessionCharCount := 0
global HasBackspaced := false
global LastCharWasTypo := false

; Toolbar registry
global ActiveBars := Map()      ; TargetHWnd -> BarObject

; -------------------------------------------------------------
; 1. SAVED POSITION (fractions of the monitor's free space)
; -------------------------------------------------------------
; PanelFracX/Y: 0 = left/top edge, 1 = right/bottom edge of the work area.
; Using free space (screen minus panel size) guarantees the panel always fits.
global PanelFracX := 1.0
global PanelFracY := 1.0
global PanelMon := MonitorGetPrimary()
global HavePos := false

try {
    sx := IniRead(IniFile, "Position", "FracX", "")
    sy := IniRead(IniFile, "Position", "FracY", "")
    if (sx != "" && sy != "") {
        PanelFracX := Float(sx)
        PanelFracY := Float(sy)
        PanelMon := Integer(IniRead(IniFile, "Position", "Monitor", String(MonitorGetPrimary())))
        HavePos := true
    }
}

; -------------------------------------------------------------
; 2. FLOATING CONTROL PANEL INTERFACE
; -------------------------------------------------------------
MainGui := Gui("+AlwaysOnTop +ToolWindow -Caption +Border +E0x08000000", "LeoType")
MainGui.BackColor := "000000"

BtnStyle := "Background000000 c00FF00 +Center +Border +0x200"
WinCtrlStyle := "Background000000 c00FF00 +Center +0x200"

; --- Top Right Tiny Window Control Headers ---
MainGui.SetFont("s7 c00FF00 q5", "Consolas")
global BtnTog := MainGui.Add("Text", "x207 y5 w14 h14 +Border " WinCtrlStyle, "T")   ; show/hide Inject Toolbar row
global BtnMin := MainGui.Add("Text", "x225 y5 w14 h14 +Border " WinCtrlStyle, "-")
global BtnCls := MainGui.Add("Text", "x243 y5 w14 h14 +Border " WinCtrlStyle, "X")

; --- Top Center Title ---
MainGui.SetFont("s10 c00FF00 q5 bold", "Consolas")
global TitleText := MainGui.Add("Text", "x5 y4 w200 h18 +Center +0x200", "---LeoType---")

; --- Row 1 Core Functional Buttons ---
MainGui.SetFont("s9 c00FF00 q5", "Consolas")
global Btn1 := MainGui.Add("Text", "x10 y23 w115 h30 " BtnStyle, "[ Human Type ]")
global Btn2 := MainGui.Add("Text", "x135 y23 w115 h30 " BtnStyle, "[ STOP ]")

; --- Row 2 Functional Buttons ---
global Btn3 := MainGui.Add("Text", "x10 y58 w55 h30 " BtnStyle, "Copy")
global Btn4 := MainGui.Add("Text", "x70 y58 w95 h30 " BtnStyle, "Paste+Enter")
global Btn5 := MainGui.Add("Text", "x170 y58 w80 h30 " BtnStyle, "Screenshot")

; --- Row 3 Toolbar Injector (can be hidden) ---
global Btn6 := MainGui.Add("Text", "x10 y93 w240 h26 " BtnStyle, "[ Inject Toolbar ]")

; --- Row 4 System Terminal Status Bar & Speed Shifter ---
MainGui.SetFont("s8 c00FF00 q5", "Consolas")
global StatusBar := MainGui.Add("Text", "x10 y126 w150 h20 +0x200", "[ STATUS: READY ]")
global SpeedDisplay := MainGui.Add("Text", "x165 y126 w45 h20 +Center +0x200", "1.0x")
global BtnSpdDown := MainGui.Add("Text", "x215 y127 w16 h18 +Border " WinCtrlStyle, "-")
global BtnSpdUp := MainGui.Add("Text", "x235 y127 w16 h18 +Border " WinCtrlStyle, "+")

; Apply saved show/hide state of the Inject Toolbar row (before first Show)
ApplyLayout(false)

; Register custom low-level window message hooks
OnMessage(0x0020, WM_SETCURSOR)
OnMessage(0x0232, WM_EXITSIZEMOVE)    ; save position after every drag
OnMessage(0x007E, WM_DISPLAYCHANGE)   ; resolution / monitor change

; Global mouse hook for reliable click detection
global MouseHook := DllCall("SetWindowsHookEx", "int", 14, "ptr", CallbackCreate(MouseProc, "C"), "ptr", 0, "uint", 0, "ptr")

; Runs on every exit path (panel X button, tray menu Exit, etc.)
OnExit(CleanupOnExit)

; Create hidden, place, then show (avoids a visible jump)
MainGui.Show("Hide w" PanelWidth " h" PanelHeight)
if HavePos
    ApplyPanelPosition()
else
    PlaceDefaultPosition()
MainGui.Show("NoActivate")

; -------------------------------------------------------------
; 3. POSITION / RESOLUTION HANDLING
; -------------------------------------------------------------
SetTimer(CheckResolutionChange, 500)
SetTimer(SystemSyncEngine, 30)   ; toolbar docking / hover sync

Clamp(v, lo, hi) {
    return Min(hi, Max(lo, v))
}

; Which monitor currently holds the centre of the panel
GetPanelMonitor() {
    MainGui.GetPos(&X, &Y, &W, &H)
    cx := X + W // 2
    cy := Y + H // 2
    Loop MonitorGetCount() {
        MonitorGetWorkArea(A_Index, &L, &T, &R, &B)
        if (cx >= L && cx < R && cy >= T && cy < B)
            return A_Index
    }
    return MonitorGetPrimary()
}

; Remember where the panel is, as fractions of the monitor's free space
SavePositionRatios() {
    global PanelFracX, PanelFracY, PanelMon, IniFile, HavePos
    try {
        MainGui.GetPos(&X, &Y, &W, &H)
        Mon := GetPanelMonitor()
        MonitorGetWorkArea(Mon, &L, &T, &R, &B)
        FreeW := (R - L) - W
        FreeH := (B - T) - H
        PanelFracX := FreeW > 0 ? Clamp((X - L) / FreeW, 0, 1) : 0
        PanelFracY := FreeH > 0 ? Clamp((Y - T) / FreeH, 0, 1) : 0
        PanelMon := Mon
        HavePos := true
        IniWrite(String(PanelFracX), IniFile, "Position", "FracX")
        IniWrite(String(PanelFracY), IniFile, "Position", "FracY")
        IniWrite(String(PanelMon), IniFile, "Position", "Monitor")
    }
}

; Move the panel to the remembered relative position on the current layout
ApplyPanelPosition() {
    global PanelFracX, PanelFracY, PanelMon
    Mon := PanelMon
    if (Mon < 1 || Mon > MonitorGetCount())
        Mon := MonitorGetPrimary()

    MonitorGetWorkArea(Mon, &L, &T, &R, &B)
    MainGui.GetPos(, , &W, &H)
    FreeW := Max(0, (R - L) - W)
    FreeH := Max(0, (B - T) - H)
    MainGui.Move(L + Round(PanelFracX * FreeW), T + Round(PanelFracY * FreeH))
}

; Bottom-right corner of the primary monitor (first launch / Reset Position)
PlaceDefaultPosition() {
    MonitorGetWorkArea(MonitorGetPrimary(), &L, &T, &R, &B)
    MainGui.GetPos(, , &W, &H)
    MainGui.Move(R - W - 15, B - H - 15)
    SavePositionRatios()
}

; Detect any change in monitor count or work-area size and re-apply the position
CheckResolutionChange() {
    static LastSig := ""
    Sig := MonitorGetCount()
    Loop MonitorGetCount() {
        MonitorGetWorkArea(A_Index, &L, &T, &R, &B)
        Sig .= "|" L "," T "," R "," B
    }

    if (LastSig == "") {
        LastSig := Sig      ; first run: just record
        return
    }

    if (Sig != LastSig) {
        LastSig := Sig
        ApplyPanelPosition()
    }
}

; Windows tells us the display mode changed: re-check shortly after it settles
WM_DISPLAYCHANGE(wParam, lParam, msg, hwnd) {
    SetTimer(CheckResolutionChange, -300)
}

; Show/hide the Inject Toolbar row and resize the panel to save space
ToggleInjectRow() {
    global InjectVisible, IniFile
    InjectVisible := !InjectVisible
    try IniWrite(InjectVisible ? "1" : "0", IniFile, "UI", "InjectVisible")
    ApplyLayout(true)
}

; The panel's BOTTOM edge stays fixed: it shrinks/grows from the top.
ApplyLayout(Resize := true) {
    global InjectVisible, PanelHeight, PanelWidth
    global Btn6, StatusBar, SpeedDisplay, BtnSpdDown, BtnSpdUp

    OldHeight := PanelHeight

    if InjectVisible {
        Btn6.Visible := true
        StatusY := 126
        PanelHeight := 155
    } else {
        Btn6.Visible := false
        StatusY := 93
        PanelHeight := 122
    }

    StatusBar.Move(, StatusY)
    SpeedDisplay.Move(, StatusY)
    BtnSpdDown.Move(, StatusY + 1)
    BtnSpdUp.Move(, StatusY + 1)

    if Resize {
        MainGui.GetPos(&X, &Y)
        MonitorGetWorkArea(GetPanelMonitor(), &L, &T, &R, &B)
        NewY := Clamp(Y + (OldHeight - PanelHeight), T, B - PanelHeight)
        MainGui.Show("x" X " y" NewY " w" PanelWidth " h" PanelHeight " NoActivate")
        SavePositionRatios()
    }
}

; -------------------------------------------------------------
; 4. KEYBOARD HOTKEY CAPTURES
; -------------------------------------------------------------
!v:: {
    ClickedHumanType()
}

; -------------------------------------------------------------
; 5. GLOBAL MOUSE HOOK FOR RELIABLE CLICK DETECTION
; -------------------------------------------------------------
IsMouseOverCtrl(CtrlObj, mouseX, mouseY) {
    CtrlObj.GetPos(&cX, &cY, &cW, &cH)
    return (mouseX >= cX && mouseX <= cX + cW && mouseY >= cY && mouseY <= cY + cH)
}

GetAdjacentKey(char) {
    static rows := [
        "`1234567890-=",
        "qwertyuiop[]",
        "asdfghjkl;'",
        "zxcvbnm,./"
    ]

    For row, keys in rows {
        pos := InStr(keys, char)
        if (pos) {
            dir := Random(1, 2)  ; 1=left, 2=right
            if (dir = 1 && pos > 1) {
                return SubStr(keys, pos - 1, 1)
            } else if (dir = 2 && pos < StrLen(keys)) {
                return SubStr(keys, pos + 1, 1)
            } else {
                if (pos > 1)
                    return SubStr(keys, pos - 1, 1)
                else if (pos < StrLen(keys))
                    return SubStr(keys, pos + 1, 1)
            }
        }
    }

    return Chr(Ord(char) + Random(-2, 2))
}

GetAlternateKey(char) {
    static commonTypos := Map(
        "a", "s", "s", "a", "d", "f", "f", "d", "g", "h", "h", "g",
        "j", "k", "k", "j", "l", "p", "p", "l", "q", "w", "w", "q",
        "e", "r", "r", "e", "t", "y", "y", "t", "u", "i", "i", "u",
        "o", "p", "p", "o", "z", "x", "x", "z", "c", "v", "v", "c",
        "b", "n", "n", "b", "m", "n"
    )

    if commonTypos.Has(char) {
        return commonTypos[char]
    }

    return Chr(Ord(char) + Random(1, 2))
}

MouseProc(nCode, wParam, lParam) {
    global MainGui, Btn1, Btn2, Btn3, Btn4, Btn5, Btn6, BtnTog, BtnMin, BtnCls, BtnSpdUp, BtnSpdDown, InjectVisible

    ; Only react while the panel is actually visible. When it is hidden/minimized
    ; its old screen area must NOT swallow clicks.
    if (nCode >= 0 && wParam = 0x0201 && DllCall("user32\IsWindowVisible", "Ptr", MainGui.Hwnd)) { ; WM_LBUTTONDOWN
        POINT := Buffer(8)
        DllCall("GetCursorPos", "ptr", POINT)
        mouseX := NumGet(POINT, 0, "Int")
        mouseY := NumGet(POINT, 4, "Int")

        RECT := Buffer(16)
        DllCall("GetWindowRect", "ptr", MainGui.Hwnd, "ptr", RECT)
        winX := NumGet(RECT, 0, "Int")
        winY := NumGet(RECT, 4, "Int")
        winW := NumGet(RECT, 8, "Int") - winX
        winH := NumGet(RECT, 12, "Int") - winY

        if (mouseX >= winX && mouseX <= winX + winW && mouseY >= winY && mouseY <= winY + winH) {
            X := mouseX - winX
            Y := mouseY - winY

            if IsMouseOverCtrl(Btn1, X, Y) {
                TriggerVisualFeedback(Btn1)
                ClickedHumanType()
                return 1
            }
            if IsMouseOverCtrl(Btn2, X, Y) {
                TriggerVisualFeedback(Btn2)
                ClickedStop()
                return 1
            }
            if IsMouseOverCtrl(Btn3, X, Y) {
                TriggerVisualFeedback(Btn3)
                ClickedCopy()
                return 1
            }
            if IsMouseOverCtrl(Btn4, X, Y) {
                TriggerVisualFeedback(Btn4)
                SetTimer(ClickedPaste, -10)   ; deferred: must not block the hook
                return 1
            }
            if IsMouseOverCtrl(Btn5, X, Y) {
                TriggerVisualFeedback(Btn5)
                ClickedScreenshot()
                return 1
            }
            if (InjectVisible && IsMouseOverCtrl(Btn6, X, Y)) {
                TriggerVisualFeedback(Btn6)
                SetTimer(InjectToolbarToActiveWindow, -10)
                return 1
            }
            if IsMouseOverCtrl(BtnTog, X, Y) {
                TriggerVisualFeedback(BtnTog)
                SetTimer(ToggleInjectRow, -10)
                return 1
            }
            if IsMouseOverCtrl(BtnMin, X, Y) {
                TriggerVisualFeedback(BtnMin)
                SetTimer(ClickedMinimize, -10)
                return 1
            }
            if IsMouseOverCtrl(BtnCls, X, Y) {
                TriggerVisualFeedback(BtnCls)
                SetTimer(CompleteShutdown, -10)
                return 1
            }
            if IsMouseOverCtrl(BtnSpdUp, X, Y) {
                TriggerVisualFeedback(BtnSpdUp)
                AdjustSpeedUp()
                return 1
            }
            if IsMouseOverCtrl(BtnSpdDown, X, Y) {
                TriggerVisualFeedback(BtnSpdDown)
                AdjustSpeedDown()
                return 1
            }

            ; Anywhere else on the panel: start dragging the window.
            ; (WM_NCLBUTTONDOWN + HTCAPTION. The "ahk_id" prefix is required,
            ; otherwise the handle is treated as a window title and nothing moves.)
            PostMessage(0xA1, 2, 0, , "ahk_id " MainGui.Hwnd)
            return 1
        }
    }

    return DllCall("CallNextHookEx", "ptr", 0, "int", nCode, "uptr", wParam, "ptr", lParam, "ptr")
}

WM_SETCURSOR(wParam, lParam, msg, hwnd) {
    global InjectVisible
    if (hwnd == MainGui.Hwnd) {
        MouseGetPos &mX, &mY
        MainGui.GetPos(&wX, &wY)
        localX := mX - wX
        localY := mY - wY

        if (IsMouseOverCtrl(Btn1, localX, localY) || IsMouseOverCtrl(Btn2, localX, localY)
         || IsMouseOverCtrl(Btn3, localX, localY) || IsMouseOverCtrl(Btn4, localX, localY)
         || IsMouseOverCtrl(Btn5, localX, localY) || (InjectVisible && IsMouseOverCtrl(Btn6, localX, localY))
         || IsMouseOverCtrl(BtnTog, localX, localY)
         || IsMouseOverCtrl(BtnCls, localX, localY) || IsMouseOverCtrl(BtnMin, localX, localY)
         || IsMouseOverCtrl(BtnSpdDown, localX, localY) || IsMouseOverCtrl(BtnSpdUp, localX, localY)) {
            HandCursor := DllCall("user32\LoadCursor", "Ptr", 0, "Ptr", 32649, "Ptr")
            DllCall("user32\SetCursor", "Ptr", HandCursor)
            return true
        }
    }
}

; Remember the panel position after every drag
WM_EXITSIZEMOVE(wParam, lParam, msg, hwnd) {
    if (hwnd == MainGui.Hwnd)
        SavePositionRatios()
}

TriggerVisualFeedback(CtrlObj) {
    CtrlObj.Opt("Background00FF00 c000000")
    CtrlObj.Redraw()
    SetTimer(() => ResetVisualFeedback(CtrlObj), -120)
}

ResetVisualFeedback(CtrlObj) {
    try {
        CtrlObj.Opt("Background000000 c00FF00")
        CtrlObj.Redraw()
    }
}

AH_TrayIconInteraction(wParam, lParam, msg, hwnd) {
    if (lParam == 0x0202) {
        ToggleUiVisibility()
    }
}

ToggleUiVisibility() {
    if DllCall("user32\IsWindowVisible", "Ptr", MainGui.Hwnd) {
        MainGui.Hide()
    } else {
        MainGui.Show("NoActivate")
        WinSetAlwaysOnTop(1, MainGui.Hwnd)
    }
}

; -------------------------------------------------------------
; 6. SYSTEM FUNCTION ROUTING & SPEED TUNING
; -------------------------------------------------------------
ClickedMinimize() {
    ToggleUiVisibility()
}

; Paste, wait 4 seconds, then press Enter
ClickedPaste() {
    global PasteEnterDelay
    Send("^v")
    SetTimer(PressEnterAfterPaste, -PasteEnterDelay)   ; re-clicking restarts the countdown
}

PressEnterAfterPaste() {
    Send("{Enter}")
}

ClickedCopy() {
    Send("^c")
}

ClickedScreenshot() {
    Send("{PrintScreen}")
}

AdjustSpeedUp() {
    global SpeedMultiplier
    if (SpeedMultiplier < 3.0) {
        SpeedMultiplier := Round(SpeedMultiplier + 0.1, 1)
        SpeedDisplay.Text := SpeedMultiplier "x"
    }
}

AdjustSpeedDown() {
    global SpeedMultiplier
    if (SpeedMultiplier > 0.5) {
        SpeedMultiplier := Round(SpeedMultiplier - 0.1, 1)
        SpeedDisplay.Text := SpeedMultiplier "x"
    }
}

CompleteShutdown() {
    ExitApp()   ; CleanupOnExit does the rest
}

; Unhook the mouse and restore all toolbar-modified windows.
; (Position is saved after each drag, so it is not re-saved here: that could
;  record a position Windows shifted during a resolution change.)
CleanupOnExit(ExitReason, ExitCode) {
    global MouseHook, ActiveBars
    SetTimer(SystemSyncEngine, 0)
    try DllCall("UnhookWindowsHookEx", "ptr", MouseHook)

    Keys := []
    for hwnd in ActiveBars
        Keys.Push(hwnd)
    for hwnd in Keys
        RemoveToolbarInstance(hwnd)
}

; -------------------------------------------------------------
; 7. ADVANCED ASYNCHRONOUS ENGINE WITH REALISTIC TYPOS & BACKSPACE
; -------------------------------------------------------------
ClickedHumanType() {
    global IsTypingActive, TextToType, CurrentCharIndex
    global TypoCount, SessionCharCount, HasBackspaced, LastCharWasTypo

    if (IsTypingActive) {
        IsTypingActive := false
        SetTimer(ExecuteNextCharacter, 0)
        SetTimer(BlinkStatusIndicator, 0)
        StatusBar.Opt("c00FF00")
        StatusBar.Text := "[ STATUS: READY ]"
        Btn2.Text := "[ STOP ]"
        Sleep(50)
    }

    TextToType := A_Clipboard
    if (TextToType == "")
        return

    TypoCount := 0
    SessionCharCount := 0
    HasBackspaced := false
    LastCharWasTypo := false

    IsTypingActive := true
    CurrentCharIndex := 1

    StatusBar.Opt("c00FF00")
    StatusBar.Text := "[ TRANSMITTING... ]"
    Btn2.Text := "[ STOP ]"
    SetTimer(BlinkStatusIndicator, 450)
    SetTimer(ExecuteNextCharacter, 50)
}

ClickedStop() {
    global IsTypingActive
    if (!IsTypingActive)
        return

    IsTypingActive := false
    SetTimer(ExecuteNextCharacter, 0)
    SetTimer(BlinkStatusIndicator, 0)
    StatusBar.Opt("c00FF00")
    StatusBar.Text := "[ STATUS: READY ]"
    Btn2.Text := "[ STOP ]"
}

BlinkStatusIndicator() {
    global IsTypingActive
    if (!IsTypingActive) {
        SetTimer(BlinkStatusIndicator, 0)
        return
    }

    if (StatusBar.Text == "") {
        StatusBar.Text := "[ TRANSMITTING... ]"
    } else {
        StatusBar.Text := ""
    }
}

ExecuteNextCharacter() {
    global IsTypingActive, TextToType, CurrentCharIndex, SpeedMultiplier
    global TypoCount, SessionCharCount, HasBackspaced, LastCharWasTypo

    if (!IsTypingActive) {
        SetTimer(ExecuteNextCharacter, 0)
        return
    }

    if (CurrentCharIndex > StrLen(TextToType)) {
        IsTypingActive := false
        SetTimer(ExecuteNextCharacter, 0)
        StatusBar.Opt("c00FF00")
        StatusBar.Text := "[ STATUS: READY ]"
        Btn2.Text := "[ STOP ]"
        return
    }

    CurrentChar := SubStr(TextToType, CurrentCharIndex, 1)

    SessionCharCount++

    ShouldTypo := false

    if (!HasBackspaced && SessionCharCount >= 8 && SessionCharCount <= 20) {
        ShouldTypo := true
    }

    if (!ShouldTypo && !LastCharWasTypo) {
        if (CurrentChar ~= "[a-zA-Z]") {
            if (Random(1, 100) <= 8)
                ShouldTypo := true
        } else if (CurrentChar = " ") {
            if (Random(1, 100) <= 2)
                ShouldTypo := true
        } else if (CurrentChar ~= "[.,?!;:]") {
            if (Random(1, 100) <= 3)
                ShouldTypo := true
        } else {
            if (Random(1, 100) <= 5)
                ShouldTypo := true
        }
    }

    if (ShouldTypo && CurrentChar != " ") {
        WrongChar := GetAdjacentKey(CurrentChar)

        if (WrongChar == CurrentChar || WrongChar == "") {
            WrongChar := GetAlternateKey(CurrentChar)
        }

        SendInput("{Raw}" . WrongChar)
        Sleep(Random(80, 180))

        SendInput("{Backspace}")
        HasBackspaced := true
        TypoCount++
        LastCharWasTypo := true
        Sleep(Random(60, 140))

        SendInput("{Raw}" . CurrentChar)
        CurrentCharIndex++

        BaseDelay := Random(100, 250)

    } else {
        SendInput("{Raw}" . CurrentChar)
        CurrentCharIndex++
        LastCharWasTypo := false

        BaseDelay := Random(80, 140)

        if (CurrentChar ~= "[A-Z!@#$%^&*()_+{}|:<>?]") {
            BaseDelay += Random(35, 75)
        }
        if (CurrentChar = " ") {
            BaseDelay += Random(80, 180)
        } else if (CurrentChar ~= "[.,?!;:]") {
            BaseDelay += Random(250, 450)
        }

        if (Random(1, 100) <= 4) {
            BaseDelay += Random(200, 500)
        }
    }

    TargetDelay := Max(10, Round(BaseDelay / SpeedMultiplier))
    SetTimer(ExecuteNextCharacter, TargetDelay)
}

; -------------------------------------------------------------
; 8. WINDOW TOOLBAR SYSTEM (one toolbar per window)
; -------------------------------------------------------------
InjectToolbarToActiveWindow() {
    global ActiveBars

    ; The panel is NoActivate and its clicks are swallowed by the hook,
    ; so the active window is still the one the user was working in.
    TargetHWnd := WinExist("A")

    if (!TargetHWnd || TargetHWnd == MainGui.Hwnd) {
        HackerConsoleFeedback("ERROR: VOID TARGET")
        return
    }

    ; Don't attach to the taskbar / desktop
    try {
        Cls := WinGetClass(TargetHWnd)
        if (Cls == "Shell_TrayWnd" || Cls == "Progman" || Cls == "WorkerW") {
            HackerConsoleFeedback("ERROR: INVALID TARGET")
            return
        }
    }

    ; Never attach a toolbar to another toolbar
    for , bar in ActiveBars {
        if (bar.Destroyed)
            continue
        BarHwnd := 0
        try BarHwnd := bar.Gui.Hwnd
        if (BarHwnd == TargetHWnd) {
            HackerConsoleFeedback("ERROR: TARGET IS A TOOLBAR")
            return
        }
    }

    ; Only one toolbar per window
    if ActiveBars.Has(TargetHWnd) {
        HackerConsoleFeedback("ALREADY ATTACHED")
        return
    }

    ActiveBars[TargetHWnd] := WindowBarInstance(TargetHWnd)
    HackerConsoleFeedback("DOCK PIPELINE ACTIVE")
}

class WindowBarInstance {
    __New(TargetHWnd) {
        this.TargetHWnd := TargetHWnd
        this.IsHovered := false
        this.Destroyed := false
        this.CurrentMode := "FULL"  ; "FULL" or "MINI"
        this.AlphaPct := 60         ; target window opacity in percent (20-100)
        this.ShowAlphaCtrls := true ; show/hide the [-] 60% [+] controls
        this.Gui := 0
        this.BtnPin := 0
        this.BtnAlpha := 0
        this.BtnAlphaTog := 0
        this.BtnAlphaDown := 0
        this.AlphaDisplay := 0
        this.BtnAlphaUp := 0
        this.BtnPhase := 0
        this.BtnHide := 0
        this.BtnMore := 0
        this.BtnClose := 0

        this.States := Map("PIN", false, "ALPHA", false, "PHASE", false, "HIDE", false)

        WinGetPos(&WX, &WY, &WW, &WH, TargetHWnd)
        this.RenderControls(WW)
        this.Gui.Show(Format("x{} y{} w{} h35 NoActivate", WX, WY - 35, WW))
    }

    ; Width below which the toolbar uses the compact [...] layout
    MinWidth() {
        global FullMinWidth, FullMinWidthNoAlpha
        return this.ShowAlphaCtrls ? FullMinWidth : FullMinWidthNoAlpha
    }

    ; AHK v2 controls cannot be deleted individually, so the bar GUI is rebuilt
    ; whenever the layout changes. The NEW gui is built and swapped in first and
    ; the old one destroyed last, and the whole thing is Critical so the sync
    ; timer can never see a bar without a valid window.
    RenderControls(Width) {
        Critical

        OldGui := this.Gui

        g := Gui("+AlwaysOnTop -Caption +ToolWindow +Owner" this.TargetHWnd)
        g.BackColor := "000000"
        g.SetFont("s9 c00FF00 Bold", "Consolas")

        this.BtnAlpha := 0
        this.BtnAlphaTog := 0
        this.BtnAlphaDown := 0
        this.AlphaDisplay := 0
        this.BtnAlphaUp := 0
        this.BtnPhase := 0
        this.BtnHide := 0
        this.BtnMore := 0

        if (Width < this.MinWidth()) {
            this.CurrentMode := "MINI"

            this.BtnPin   := g.Add("Text", "x10 y8 h24 Center +Border +Background000000", " [PIN] ")
            this.BtnMore  := g.Add("Text", "x+10 y8 h24 Center +Border +Background000000", " [...] ")
            this.BtnClose := g.Add("Text", "x+15 y8 h24 Center +Border +Background000000 cFF0000", " [X] ")

            this.BtnPin.OnEvent("Click", (*) => this.TogglePin())
            this.BtnMore.OnEvent("Click", (*) => this.ShowOverflowMenu())
            this.BtnClose.OnEvent("Click", (*) => RemoveToolbarInstance(this.TargetHWnd))
        } else {
            this.CurrentMode := "FULL"

            this.BtnPin   := g.Add("Text", "x10 y8 h24 Center +Border +Background000000", " [PIN] ")
            this.BtnAlpha := g.Add("Text", "x+10 y8 h24 Center +Border +Background000000", " [ALPHA] ")
            this.BtnAlphaTog := g.Add("Text", "x+4 y8 w34 h24 Center +Border +0x200 +Background000000", "[±]")
            if this.ShowAlphaCtrls {
                this.BtnAlphaDown := g.Add("Text", "x+4 y8 w30 h24 Center +Border +0x200 +Background000000", "[-]")
                this.AlphaDisplay := g.Add("Text", "x+4 y8 w46 h24 Center +Border +0x200 +Background000000", this.AlphaPct "%")
                this.BtnAlphaUp   := g.Add("Text", "x+4 y8 w30 h24 Center +Border +0x200 +Background000000", "[+]")
            }
            this.BtnPhase := g.Add("Text", "x+10 y8 h24 Center +Border +Background000000", " [PHASE] ")
            this.BtnHide  := g.Add("Text", "x+10 y8 h24 Center +Border +Background000000", " [HIDE] ")
            this.BtnClose := g.Add("Text", "x+20 y8 h24 Center +Border +Background000000 cFF0000", " [X] ")

            this.BtnPin.OnEvent("Click", (*) => this.TogglePin())
            this.BtnAlpha.OnEvent("Click", (*) => this.ToggleAlpha())
            ; Deferred: the toggle rebuilds the GUI this click came from
            this.BtnAlphaTog.OnEvent("Click", (*) => SetTimer(() => this.ToggleAlphaControls(), -1))
            if this.ShowAlphaCtrls {
                this.BtnAlphaDown.OnEvent("Click", (*) => this.AdjustAlpha(-10))
                this.BtnAlphaUp.OnEvent("Click", (*) => this.AdjustAlpha(10))
            }
            this.BtnPhase.OnEvent("Click", (*) => this.TogglePhase())
            this.BtnHide.OnEvent("Click", (*) => this.ToggleHide())
            this.BtnClose.OnEvent("Click", (*) => RemoveToolbarInstance(this.TargetHWnd))
        }

        ; Swap in the new GUI, then dispose of the old one
        this.Gui := g
        this.ApplyStateHighlights()
        g.Show("Hide")
        WinSetTransparent(this.IsHovered ? 210 : 40, g.Hwnd)

        if OldGui {
            try OldGui.Destroy()
        }
    }

    ; Show/hide the transparency adjust controls to save space
    ToggleAlphaControls() {
        Critical
        if (this.Destroyed || !WinExist(this.TargetHWnd))
            return
        this.ShowAlphaCtrls := !this.ShowAlphaCtrls
        WinGetPos(&WX, &WY, &WW, &WH, this.TargetHWnd)
        this.RenderControls(WW)
        this.Gui.Show(Format("x{} y{} w{} h35 NoActivate", WX, WY - 35, WW))
    }

    ApplyStateHighlights() {
        if (this.BtnPin) {
            this.BtnPin.Opt(this.States["PIN"] ? "+Background004400" : "+Background000000")
            this.BtnPin.Redraw()
        }
        if (this.CurrentMode == "FULL") {
            this.BtnAlpha.Opt(this.States["ALPHA"] ? "+Background004400" : "+Background000000")
            this.BtnAlpha.Redraw()
            if (this.BtnAlphaTog) {
                this.BtnAlphaTog.Opt(this.ShowAlphaCtrls ? "+Background004400" : "+Background000000")
                this.BtnAlphaTog.Redraw()
            }
            if (this.AlphaDisplay) {
                this.AlphaDisplay.Opt(this.States["ALPHA"] ? "+Background004400" : "+Background000000")
                this.AlphaDisplay.Text := this.AlphaPct "%"
                this.AlphaDisplay.Redraw()
            }
            this.BtnPhase.Opt(this.States["PHASE"] ? "+Background004400" : "+Background000000")
            this.BtnHide.Opt(this.States["HIDE"] ? "+Background004400" : "+Background000000")
            this.BtnPhase.Redraw()
            this.BtnHide.Redraw()
        }
    }

    ShowOverflowMenu() {
        OverflowMenu := Menu()

        AlphaCheck := this.States["ALPHA"] ? "✓ [ALPHA] Transparency"  : "  [ALPHA] Transparency"
        PhaseCheck := this.States["PHASE"] ? "✓ [PHASE] Click-Through" : "  [PHASE] Click-Through"
        HideCheck  := this.States["HIDE"]  ? "✓ [HIDE] Invisible"      : "  [HIDE] Invisible"

        OverflowMenu.Add(AlphaCheck, (*) => this.ToggleAlpha())
        OverflowMenu.Add("  Alpha +  (now " this.AlphaPct "%)", (*) => this.AdjustAlpha(10))
        OverflowMenu.Add("  Alpha -  (now " this.AlphaPct "%)", (*) => this.AdjustAlpha(-10))
        OverflowMenu.Add(PhaseCheck, (*) => this.TogglePhase())
        OverflowMenu.Add(HideCheck,  (*) => this.ToggleHide())

        OverflowMenu.Show()
    }

    ; Converts the percentage (20-100) to the 0-255 value WinSetTransparent expects
    AlphaValue() {
        return Round(this.AlphaPct / 100 * 255)
    }

    ; Single place that applies ALPHA / PHASE / HIDE to the target window,
    ; so the three features combine correctly.
    ApplyWindowEffects() {
        if !WinExist(this.TargetHWnd)
            return

        Hidden := this.States["HIDE"]

        if Hidden
            WinSetTransparent(0, this.TargetHWnd)
        else if this.States["ALPHA"]
            WinSetTransparent(this.AlphaValue(), this.TargetHWnd)
        else
            WinSetTransparent("Off", this.TargetHWnd)

        ; An invisible window must also be click-through
        if (Hidden || this.States["PHASE"]) {
            WinSetExStyle("+0x80000", this.TargetHWnd) ; WS_EX_LAYERED
            WinSetExStyle("+0x20", this.TargetHWnd)    ; WS_EX_TRANSPARENT
        } else {
            WinSetExStyle("-0x20", this.TargetHWnd)
        }
    }

    TogglePin() {
        if !WinExist(this.TargetHWnd)
            return
        this.States["PIN"] := !this.States["PIN"]
        WinSetAlwaysOnTop(this.States["PIN"] ? 1 : 0, this.TargetHWnd)
        this.ApplyStateHighlights()
        HackerConsoleFeedback(this.States["PIN"] ? "PIN ACTIVE" : "PIN OFF")
    }

    ToggleAlpha() {
        if !WinExist(this.TargetHWnd)
            return
        this.States["ALPHA"] := !this.States["ALPHA"]
        this.ApplyWindowEffects()
        this.ApplyStateHighlights()
        HackerConsoleFeedback(this.States["ALPHA"] ? "ALPHA " this.AlphaPct "%" : "ALPHA RESTORED")
    }

    ; Change transparency level; turns ALPHA on if it was off
    AdjustAlpha(Delta) {
        if !WinExist(this.TargetHWnd)
            return
        this.AlphaPct := Min(100, Max(20, this.AlphaPct + Delta))
        this.States["ALPHA"] := true
        this.ApplyWindowEffects()
        this.ApplyStateHighlights()
        HackerConsoleFeedback("ALPHA " this.AlphaPct "%")
    }

    TogglePhase() {
        if !WinExist(this.TargetHWnd)
            return
        this.States["PHASE"] := !this.States["PHASE"]
        this.ApplyWindowEffects()
        this.ApplyStateHighlights()
        HackerConsoleFeedback(this.States["PHASE"] ? "GHOST PHASE INJECTED" : "PHASE OVER")
    }

    ; Make the target window completely invisible (and click-through).
    ; The toolbar stays visible so the window can be brought back.
    ToggleHide() {
        if !WinExist(this.TargetHWnd)
            return
        this.States["HIDE"] := !this.States["HIDE"]
        this.ApplyWindowEffects()
        this.ApplyStateHighlights()
        HackerConsoleFeedback(this.States["HIDE"] ? "WINDOW INVISIBLE" : "WINDOW VISIBLE")
    }

    DestroyInstance() {
        this.Destroyed := true   ; sync engine must ignore this bar from now on

        if WinExist(this.TargetHWnd) {
            WinSetAlwaysOnTop(0, this.TargetHWnd)
            WinSetTransparent("Off", this.TargetHWnd)
            WinSetExStyle("-0x20", this.TargetHWnd)
        }
        try this.Gui.Destroy()
    }
}

RemoveToolbarInstance(TargetHWnd) {
    global ActiveBars
    if ActiveBars.Has(TargetHWnd) {
        bar := ActiveBars[TargetHWnd]
        ActiveBars.Delete(TargetHWnd)   ; unregister FIRST so the timer can't see a dead GUI
        bar.DestroyInstance()
    }
}

SystemSyncEngine() {
    global ActiveBars
    Critical

    MouseGetPos(&MX, &MY, &MouseWinHWnd)

    PendingDeletions := []

    for targetHWnd, barObj in ActiveBars {
        if (barObj.Destroyed)
            continue

        if !WinExist(targetHWnd) {
            PendingDeletions.Push(targetHWnd)
            continue
        }

        ; Defensive: skip a bar whose GUI doesn't currently exist
        GuiHwnd := 0
        try GuiHwnd := barObj.Gui.Hwnd
        if !GuiHwnd
            continue

        WinGetPos(&WX, &WY, &WW, &WH, targetHWnd)

        MinW := barObj.MinWidth()
        if (barObj.CurrentMode == "FULL" && WW < MinW) {
            barObj.RenderControls(WW)
        } else if (barObj.CurrentMode == "MINI" && WW >= MinW) {
            barObj.RenderControls(WW)
        }

        ; The GUI may have been replaced by RenderControls
        try GuiHwnd := barObj.Gui.Hwnd

        if (MouseWinHWnd == GuiHwnd || (MX >= WX && MX <= WX + WW && MY >= WY - 38 && MY <= WY)) {
            if !barObj.IsHovered {
                WinSetTransparent(210, GuiHwnd)
                barObj.IsHovered := true
            }
        } else {
            if barObj.IsHovered {
                WinSetTransparent(40, GuiHwnd)
                barObj.IsHovered := false
            }
        }

        barObj.Gui.Show(Format("x{} y{} w{} h35 NoActivate", WX, WY - 35, WW))
    }

    for deadHWnd in PendingDeletions {
        RemoveToolbarInstance(deadHWnd)
    }
}

HackerConsoleFeedback(Text) {
    ToolTip("⚡ " Text " ⚡")
    SetTimer(() => ToolTip(), -1400)
}