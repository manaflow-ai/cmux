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

/// Where Settings… opens (`settings.presentation`, DEV and NIGHTLY): a tab
/// in the active window's focused pane (lane 20, Lawrence 2026-10-02), or
/// the separate window it used to be. Debug Settings follows the same
/// choice. Release builds open the tab.
public enum SettingsPresentation: String, Sendable, CaseIterable, TunableChoice {
    case pane
    case window

    public var tunableTitle: String {
        switch self {
        case .pane: "Tab in the focused pane"
        case .window: "Separate window"
        }
    }
}

/// Debug Settings declarations of the Settings window.
extension SettingsWindowLayout {
    public static let tunableSection = TunableSection(id: "settingsWindow", title: "Settings Window", symbol: "gearshape", order: 46)

    public static let tunable = Tunable<SettingsWindowLayout>.choice(
        "settings.layout", tunableSection, "Layout", help: "Prototype layout of the Settings window. Switches live.",
        default: .pages, code: "SettingsWindowLayout.tunable")

    public static let presentation = Tunable<SettingsPresentation>.choice(
        "settings.presentation", tunableSection, "Opens as",
        help: "Settings and Debug Settings open as a tab in the focused pane or as a separate window.",
        default: .pane, code: "SettingsWindowLayout.presentation")

    public static var tunables: [TunableDescriptor] { [tunable.descriptor, presentation.descriptor] }
}
