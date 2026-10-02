public import CMUXMobileCore

extension ThemeInput {
    /// The theme a mobile terminal renders with, so the phone's chrome
    /// derives the same tokens as the Mac's for the same colors.
    ///
    /// ```swift
    /// let tokens = ThemeTokens.derive(from: ThemeInput(terminalTheme: .monokai))
    /// ```
    ///
    /// - Parameters:
    ///   - terminalTheme: The terminal's colors.
    ///   - backgroundOpacity: `background-opacity`, clamped to 0...1; opaque by default.
    ///   - backgroundBlur: `background-blur` as Ghostty encodes it; off by default.
    public init(terminalTheme: TerminalTheme, backgroundOpacity: Double = 1, backgroundBlur: Int = 0) {
        self = .ghosttyDefault
    }
}
