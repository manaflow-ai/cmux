import Foundation

/// The All Themes playground's strings (``AllThemesPlaygroundView``, DEV and NIGHTLY).
struct AllThemesPlaygroundStrings {
    static var windowTitle: String { String(localized: "theme.playground.windowTitle", defaultValue: "All Themes", bundle: .l10n) }
    static var search: String { String(localized: "theme.playground.search", defaultValue: "Search themes", bundle: .l10n) }
    static var failuresOnly: String { String(localized: "theme.playground.failuresOnly", defaultValue: "Failures only", bundle: .l10n) }
    static var light: String { String(localized: "theme.playground.light", defaultValue: "Light", bundle: .l10n) }
    static var dark: String { String(localized: "theme.playground.dark", defaultValue: "Dark", bundle: .l10n) }

    /// "3 of 622 themes fail".
    static func summary(failing: Int, total: Int) -> String {
        String(format: String(localized: "theme.playground.summary", defaultValue: "%lld of %lld themes fail", bundle: .l10n),
               failing, total)
    }

    /// "2 failing".
    static func failing(_ count: Int) -> String {
        String(format: String(localized: "theme.playground.failing", defaultValue: "%lld failing", bundle: .l10n), count)
    }

    /// "Sidebar status dot: error on selected row: 2.4:1, needs 3:1".
    static func sampleHelp(_ sample: ThemeElementSample) -> String {
        let format = sample.followsSystemAppearance
            ? String(localized: "theme.playground.help.system", defaultValue: "%@ on %@: follows the system appearance, not the theme",
                     bundle: .l10n)
            : String(localized: "theme.playground.help.contrast", defaultValue: "%@ on %@: %@:1, needs %@:1", bundle: .l10n)
        return String(format: format, sample.element.title, sample.ground.title,
                      String(format: "%.2f", sample.contrast), String(format: "%.1f", sample.minimum))
    }
}
