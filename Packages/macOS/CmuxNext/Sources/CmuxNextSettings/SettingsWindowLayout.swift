public import CmuxNextDesign

/// Settings window layout prototypes (`settings.layout` in Debug Settings,
/// DEV and NIGHTLY only; plans/cmux-next/settings-ia.md "Two DEV variants").
/// Release builds keep `pages` until one is picked after dogfood. Declared
/// here, beside `SettingsSection`, because this module is not main-actor
/// isolated and a tunable choice is read from any thread.
public enum SettingsWindowLayout: String, Sendable, CaseIterable, TunableChoice {
    /// A: a sidebar of pages, one page at a time; search lists results that
    /// jump to the setting on its page.
    case pages
    /// B: every section stacked on one scrolling page; the sidebar is a
    /// scroll-spy index and search filters the page in place.
    case onePage

    public var tunableTitle: String {
        switch self {
        case .pages: "Pages (sidebar of pages, jump search)"
        case .onePage: "One page (scroll-spy sidebar, filter in place)"
        }
    }
}

/// Debug Settings declarations of the Settings window.
public enum SettingsWindowTunables {
    public static let section = TunableSection(id: "settingsWindow", title: "Settings Window", symbol: "gearshape", order: 46)

    public static let layout = Tunable<SettingsWindowLayout>.choice(
        "settings.layout", section, "Layout", help: "Prototype layout of the Settings window. Switches live.",
        default: .pages, code: "SettingsWindowTunables.layout")

    public static var all: [TunableDescriptor] { [layout.descriptor] }
}
