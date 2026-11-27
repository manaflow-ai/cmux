public import CmuxNextDesignTokens

/// One bundled theme in the All Themes playground: its colors and every element sample
/// (``ThemeElementAudit``), as a value the rows draw from.
public struct AllThemesPlaygroundEntry: Identifiable, Hashable, Sendable {
    /// The theme file's name.
    public let name: String
    /// Whether the theme is dark (its background darker than its foreground).
    public let isDark: Bool
    /// The theme's background.
    public let background: ThemeRGB
    /// The theme's foreground.
    public let foreground: ThemeRGB
    /// Every element sample, in audit order.
    public let samples: [ThemeElementSample]

    public var id: String { name }

    /// The samples that do not pass.
    public var failures: [ThemeElementSample] { samples.filter { !$0.passes } }
}
