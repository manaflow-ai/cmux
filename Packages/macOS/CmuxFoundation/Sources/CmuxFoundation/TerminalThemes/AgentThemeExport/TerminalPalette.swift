import Foundation

/// A complete terminal palette: every color an agent theme needs, with no gaps.
///
/// ``GhosttyThemeColors`` keeps whatever a theme file sets. This fills the
/// rest the way Ghostty draws it, so exporters never branch on a missing
/// color: Ghostty's default background, foreground and ANSI colors for
/// unset entries, and a background-to-foreground blend for an unset
/// selection.
///
/// ```swift
/// let palette = TerminalPalette(colors: GhosttyThemeColors(parsing: themeFile))
/// let accent = palette.ansi[5]
/// ```
public struct TerminalPalette: Equatable, Sendable {
    /// The terminal background.
    public let background: GhosttyThemeRGB
    /// The default text color.
    public let foreground: GhosttyThemeRGB
    /// The selection highlight behind selected text.
    public let selectionBackground: GhosttyThemeRGB
    /// ANSI colors 0 through 15: black, red, green, yellow, blue, magenta,
    /// cyan, white, then the bright variants in the same order.
    public let ansi: [GhosttyThemeRGB]

    /// Fills the gaps in `colors`.
    /// - Parameter colors: Parsed theme colors, usually a theme file overlaid by the user's config.
    public init(colors: GhosttyThemeColors) {
        let background = colors.background ?? Self.ghosttyDefaultBackground
        let foreground = colors.foreground ?? Self.ghosttyDefaultForeground
        self.background = background
        self.foreground = foreground
        self.selectionBackground = colors.selectionBackground
            ?? background.mixed(toward: foreground, amount: 0.3)
        self.ansi = Self.ghosttyDefaultPalette.indices.map { index in
            (colors.palette.indices.contains(index) ? colors.palette[index] : nil) ?? Self.ghosttyDefaultPalette[index]
        }
    }

    /// Whether the background reads as dark, by the same luminance split as
    /// ``GhosttyThemeColors/isDark``.
    public var isDark: Bool {
        background.luminance < 0.5
    }

    /// Ghostty's built-in background when no theme sets one.
    static let ghosttyDefaultBackground = GhosttyThemeRGB(red: 0x28, green: 0x2C, blue: 0x34)
    /// Ghostty's built-in foreground when no theme sets one.
    static let ghosttyDefaultForeground = GhosttyThemeRGB(red: 0xFF, green: 0xFF, blue: 0xFF)
    /// Ghostty's built-in ANSI colors for palette entries a theme leaves out
    /// (`Name.default` in Ghostty's `terminal/color.zig`).
    static let ghosttyDefaultPalette: [GhosttyThemeRGB] = [
        "#1d1f21", "#cc6666", "#b5bd68", "#f0c674", "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6",
        "#666666", "#d54e53", "#b9ca4a", "#e7c547", "#7aa6da", "#c397d8", "#70c0b1", "#eaeaea",
    ].compactMap { GhosttyThemeRGB(hex: $0) }
}
