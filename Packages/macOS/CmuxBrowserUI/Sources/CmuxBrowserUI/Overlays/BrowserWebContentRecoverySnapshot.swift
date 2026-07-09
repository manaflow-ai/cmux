public import SwiftUI

/// Pure value snapshot driving the browser panel's web-content recovery overlay:
/// the dimmed chrome backdrop plus the reload button's label, glyph, tooltip,
/// and accessibility identifier.
///
/// Every field is resolved app-side. `backgroundColor` is built from the app's
/// `browserChromeBackgroundColor`, and the label/tooltip come from the app-side
/// `String(localized:)` lookups, so the overlay renders here without reaching
/// back into the app target for localization or chrome theming.
public struct BrowserWebContentRecoverySnapshot: Sendable {
    /// Dimmed chrome backdrop color (the overlay applies its own opacity).
    public var backgroundColor: Color
    /// Localized reload-button title.
    public var reloadLabel: String
    /// SF Symbol name for the reload-button glyph.
    public var reloadSystemImage: String
    /// Localized reload-button tooltip text.
    public var reloadHelp: String
    /// Accessibility identifier applied to the reload button.
    public var accessibilityIdentifier: String

    /// Creates the web-content recovery snapshot from values resolved app-side.
    public init(
        backgroundColor: Color,
        reloadLabel: String,
        reloadSystemImage: String,
        reloadHelp: String,
        accessibilityIdentifier: String
    ) {
        self.backgroundColor = backgroundColor
        self.reloadLabel = reloadLabel
        self.reloadSystemImage = reloadSystemImage
        self.reloadHelp = reloadHelp
        self.accessibilityIdentifier = accessibilityIdentifier
    }
}
