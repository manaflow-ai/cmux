import Foundation

/// The built-in palettes available for cmux-owned application chrome.
///
/// A theme contains both light and dark variants. The selected variant is
/// resolved from ``AppearanceMode`` and the effective system appearance; the
/// terminal theme is intentionally not consulted here (that is the optional
/// follow-terminal-theme follow-up from issue #10078).
public enum ChromeThemeID: String, CaseIterable, Sendable, SettingCodable {
    /// The pixel-compatible cmux palette (the default).
    case `default` = "default"
    /// Catppuccin-inspired Latte/Mocha palette.
    case catppuccin
    /// Gruvbox-inspired light/dark palette.
    case gruvbox
    /// Solarized-inspired light/dark palette.
    case solarized

    /// A localized display name for settings and menus.
    public var displayName: String {
        switch self {
        case .default:
            return String(localized: "chrome.theme.default", defaultValue: "Default")
        case .catppuccin:
            return String(localized: "chrome.theme.catppuccin", defaultValue: "Catppuccin")
        case .gruvbox:
            return String(localized: "chrome.theme.gruvbox", defaultValue: "Gruvbox")
        case .solarized:
            return String(localized: "chrome.theme.solarized", defaultValue: "Solarized")
        }
    }
}
