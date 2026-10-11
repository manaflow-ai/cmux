public import CmuxNextDesign

/// Where Debug Settings opens (`settings.presentation`, DEV and NIGHTLY): a tab in the active
/// window's focused pane by default, or the separate desktop window when explicitly selected.
/// Settings itself is always the React page tab (R82). Declared here because this module is not
/// main-actor isolated and a tunable choice is read from any thread.
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

/// Debug Settings declarations of the presentation choice. The Swift Settings window and its
/// layout prototypes (`settings.layout`) went with R82 commit 6.
extension SettingsPresentation {
    public static let tunableSection = TunableSection(id: "settingsWindow", title: "Settings Window", symbol: "gearshape", order: 46)

    public static let tunable = Tunable<SettingsPresentation>.choice(
        "settings.presentation", tunableSection, "Debug Settings opens as",
        help: "Debug Settings opens as a tab in the focused pane or as a separate window.",
        default: .pane, code: "SettingsPresentation.tunable")

    public static var tunables: [TunableDescriptor] { [tunable.descriptor] }
}
