import Foundation

/// VoiceOver labels, values, hints and announcements of the extensions UI
/// (design spec §0.7a). Hints say what happens, not which mouse button does it.
enum BrowserExtensionAccessibilityText {
    static var crashed: String {
        String(localized: "browser.extensions.a11y.crashed", defaultValue: "Crashed")
    }

    static var disabled: String {
        String(localized: "browser.extensions.a11y.disabled", defaultValue: "Disabled")
    }

    static var runsHint: String {
        String(localized: "browser.extensions.a11y.runsHint", defaultValue: "Runs the extension")
    }

    static var reloadsHint: String {
        String(localized: "browser.extensions.a11y.reloadsHint", defaultValue: "Reloads the extension")
    }

    static var showsExtensionsHint: String {
        String(localized: "browser.extensions.a11y.showsHint", defaultValue: "Shows installed extensions")
    }

    static var siteAccess: String {
        String(localized: "browser.extensions.siteAccess", defaultValue: "Site Access and More…")
    }

    /// Announced when an extension finished installing.
    static func added(_ name: String) -> String {
        String(
            format: String(localized: "browser.extensions.a11y.added", defaultValue: "\u{201C}%@\u{201D} was added"),
            name
        )
    }
}
