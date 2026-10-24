public import CmuxNextDesignTokens

/// The design settings every window draws that move no theme color: `appearance.borders`,
/// calm mode (`ui.calm`) and the terminal face pages that show code follow. A change of any of
/// them repaints every window (``ThemeStore/repaintAll(following:)``).
public nonisolated struct WindowDrawnSettings: Equatable, Sendable {
    /// `appearance.borders`, after its Debug Settings override (``Borders/current``).
    public var borders: BorderMode
    /// `ui.calm`.
    public var calmMode: CalmMode
    /// The terminal's face (``DesignSettings/effectiveTerminalFontFamily``); nil for Ghostty's
    /// built-in face.
    public var terminalFontFamily: String?

    /// Makes the value from its parts (tests, and ``DesignSettings/windowDrawn``).
    public init(borders: BorderMode, calmMode: CalmMode, terminalFontFamily: String?) {
        self.borders = borders
        self.calmMode = calmMode
        self.terminalFontFamily = terminalFontFamily
    }
}

extension DesignSettings {
    /// What every window draws from these settings and moves no theme color; observable (it
    /// reads observed properties), so ``ThemeStore/repaintAll(following:)`` follows it.
    public var windowDrawn: WindowDrawnSettings {
        WindowDrawnSettings(borders: Borders.current.mode, calmMode: calmMode,
                            terminalFontFamily: effectiveTerminalFontFamily)
    }
}
