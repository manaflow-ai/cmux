import Foundation

/// The colors of the user's terminal theme, as the App reads them from the
/// Ghostty config (`background`, `foreground`, `palette`, `selection-*`,
/// `background-opacity`, `background-blur`). Design derives every chrome
/// color from this, so the window reads as one surface with the terminal.
public nonisolated struct ThemeInput: Hashable, Sendable {
    public var background: ThemeRGB
    public var foreground: ThemeRGB
    /// ANSI palette entries 0...15 (fewer when unknown).
    public var palette: [ThemeRGB]
    /// Set only when the config names an explicit color.
    public var selectionBackground: ThemeRGB?
    public var selectionForeground: ThemeRGB?
    /// `background-opacity`, 0...1.
    public var backgroundOpacity: Double
    /// `background-blur` as Ghostty encodes it (0 off, >0 radius, <0 macOS glass).
    public var backgroundBlur: Int

    public init(
        background: ThemeRGB,
        foreground: ThemeRGB,
        palette: [ThemeRGB] = [],
        selectionBackground: ThemeRGB? = nil,
        selectionForeground: ThemeRGB? = nil,
        backgroundOpacity: Double = 1,
        backgroundBlur: Int = 0
    ) {
        self.background = background.withAlpha(1)
        self.foreground = foreground.withAlpha(1)
        self.palette = Array(palette.prefix(16))
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.backgroundOpacity = min(max(backgroundOpacity, 0), 1)
        self.backgroundBlur = backgroundBlur
    }

    /// Ghostty's built-in default theme, used until the config is read.
    public static let ghosttyDefault = ThemeInput(
        background: ThemeRGB(hex: 0x282C34),
        foreground: ThemeRGB(hex: 0xFFFFFF),
        palette: [
            0x1D1F21, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xC5C8C6,
            0x666666, 0xD54E53, 0xB9CA4A, 0xE7C547, 0x7AA6DA, 0xC397D8, 0x70C0B1, 0xEAEAEA,
        ].map { ThemeRGB(hex: $0) }
    )
}
