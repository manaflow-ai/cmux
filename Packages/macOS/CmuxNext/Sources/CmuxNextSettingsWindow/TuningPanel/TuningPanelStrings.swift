import Foundation

/// Chrome text of the tuning panels (Localizable.xcstrings in this module). Tunable labels and help are English
/// developer text declared with the tunables, as in Debug Settings.
public nonisolated struct TuningPanelStrings {
    public nonisolated init() {}
    static var copyValues: String { text("tuningPanel.copyValues", "Copy Values") }
    static var hint: String {
        text("tuningPanel.hint", "Changes apply live and stay for this build. Copy Values puts every value on the clipboard as Swift constants.")
    }
    static func copied(_ count: Int) -> String {
        String(format: text("tuningPanel.copied", "Copied %lld values as Swift constants."), locale: Locale.current, count)
    }
    /// The sidebar rows panel's title.
    public static var sidebarRows: String { text("tuningPanel.sidebarRows", "Sidebar Row Tuner") }
    /// The browser chrome panel's title (``BrowserChromeTuning``, the Density Overlay Playground's controls).
    public static var browserChrome: String { text("tuningPanel.browserChrome", "Browser Chrome by Density") }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}
