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
        // `isValid` themes parse; anything else falls back to Ghostty's colors.
        let fallback = ThemeInput.ghosttyDefault
        self.init(
            background: Self.color(terminalTheme.background) ?? fallback.background,
            foreground: Self.color(terminalTheme.foreground) ?? fallback.foreground,
            palette: terminalTheme.palette.prefix(16).compactMap(Self.color),
            selectionBackground: terminalTheme.selectionBackgroundSemantic == nil
                ? Self.color(terminalTheme.selectionBackground) : nil,
            selectionForeground: terminalTheme.selectionForegroundSemantic == nil
                ? Self.color(terminalTheme.selectionForeground) : nil,
            backgroundOpacity: backgroundOpacity,
            backgroundBlur: backgroundBlur
        )
    }

    private static func color(_ hex: String) -> ThemeRGB? {
        TerminalTheme.rgbComponents(hex).map {
            ThemeRGB(r: UInt8($0.red), g: UInt8($0.green), b: UInt8($0.blue))
        }
    }
}
