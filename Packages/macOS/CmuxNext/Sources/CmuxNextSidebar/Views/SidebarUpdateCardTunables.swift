public import CmuxNextDesign

/// How the update card draws its Automatic Updates control (Debug Settings
/// `sidebar.updateCard.automaticControl`). Leo 2026-10-20: the filled
/// checkbox read as an unstyled native one; the default is a compact themed
/// switch at the card's text edge with the label after it (Leo 2026-10-22:
/// "he preferred the checkbox on the left").
public nonisolated enum SidebarUpdateToggleLook: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// A small switch in the theme's accent, in front of its label (the default).
    case switchControl = "switch"
    /// The earlier themed checkbox in front of the label.
    case checkbox

    public var tunableTitle: String {
        switch self {
        case .switchControl: "Switch"
        case .checkbox: "Checkbox"
        }
    }
}

nonisolated extension SidebarTunables {
    public static let updateCardAutomaticControl = Tunable<SidebarUpdateToggleLook>.choice(
        "sidebar.updateCard.automaticControl", .sidebar, "Update card Automatic Updates control",
        help: "How the update card draws its Automatic Updates control: a themed switch or the checkbox.",
        default: .switchControl, code: "SidebarTunables.updateCardAutomaticControl")

    /// Shows the Update Ready card and its preview for a pretend staged update with the newest
    /// real, published notes (the app falls back to sample notes offline). Nothing downloads or
    /// installs; turning it off follows the real updater again (`UpdateSimulation`).
    public static let simulatePendingUpdate = Tunable<Bool>.toggle(
        "sidebar.updateCard.simulatePending", .sidebar, "Simulate pending update",
        help: "Shows the Update Ready card and its changelog preview with the newest published notes. Nothing installs.",
        default: false, code: "SidebarTunables.simulatePendingUpdate")
}
