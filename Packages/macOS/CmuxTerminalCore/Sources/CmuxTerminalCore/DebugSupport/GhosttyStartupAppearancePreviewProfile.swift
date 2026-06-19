/// A startup-appearance preview profile for the DEBUG startup-appearance panel.
///
/// Each case maps to a synthetic (or real) Ghostty config the terminal loader
/// applies at startup so the appearance pipeline can be exercised without
/// editing the user's real config. The terminal config loader consults the
/// selected profile through ``TerminalStartupAppearancePreviewOverride`` and
/// ``GhosttyStartupAppearancePreviewState``.
///
/// The presentation strings (`displayName`/`detail`) live app-side as an
/// extension so `String(localized:)` binds to the app bundle and keeps its
/// non-English translations; this core carries only the config behavior.
public enum GhosttyStartupAppearancePreviewProfile: String, CaseIterable, Identifiable, Sendable {
    /// Loads the user's actual Ghostty and cmux config files.
    case realUserConfig
    /// No user theme or terminal colors, so cmux applies its managed defaults.
    case freshInstall
    /// Simulates an explicit light/dark Ghostty theme pair.
    case userThemePair
    /// Simulates one Ghostty theme applied in both appearances.
    case userSingleTheme
    /// Simulates direct terminal color settings with no theme.
    case userExplicitColors

    /// Stable identity for SwiftUI iteration and selection.
    public var id: String { rawValue }

    /// Whether this profile loads the real user config rather than synthetic
    /// preview contents.
    public var loadsRealUserConfig: Bool {
        self == .realUserConfig
    }

    /// Synthetic Ghostty config contents for this profile, resolved for the
    /// given color scheme. `nil` means leave the real config untouched (the
    /// `realUserConfig` path).
    public func previewConfigContents(
        preferredColorScheme: GhosttyConfig.ColorSchemePreference = GhosttyConfig.currentColorSchemePreference()
    ) -> String? {
        switch self {
        case .realUserConfig:
            return nil
        case .freshInstall:
            return GhosttyConfig.cmuxDefaultThemeConfigContents(
                preferredColorScheme: preferredColorScheme
            )
        case .userThemePair:
            return "theme = light:Catppuccin Latte,dark:Catppuccin Mocha"
        case .userSingleTheme:
            return "theme = Catppuccin Mocha"
        case .userExplicitColors:
            return """
            background = #101820
            foreground = #F4F7F7
            cursor-color = #FEE715
            cursor-text = #101820
            selection-background = #28536B
            selection-foreground = #F4F7F7
            palette = 0=#101820
            palette = 1=#C14953
            palette = 2=#47A025
            palette = 3=#D9A441
            palette = 4=#2E86AB
            palette = 5=#9B5DE5
            palette = 6=#00A6A6
            palette = 7=#D6D6D6
            palette = 8=#5C6672
            palette = 9=#FF6B6B
            palette = 10=#7BD88F
            palette = 11=#FFD166
            palette = 12=#54C6EB
            palette = 13=#C77DFF
            palette = 14=#4ECDC4
            palette = 15=#FFFFFF
            """
        }
    }
}
