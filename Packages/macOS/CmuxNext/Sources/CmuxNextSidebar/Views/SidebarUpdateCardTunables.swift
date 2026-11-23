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

/// How big the update card draws its Automatic Updates control (Debug Settings
/// `sidebar.updateCard.automaticSize`). Leo 2026-11-07: "at least let's just make the automatic updates
/// thing, like, bigger ... Why is the font so small in general". The default sets the label in the
/// sidebar rows' body size and grows the switch with it; Compact is the caption-size control from before.
public nonisolated enum SidebarUpdateToggleSize: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The label in the caption size, the switch an icon's size less a step (before 2026-11-09).
    case compact
    /// The label in the body size of the sidebar's rows, the switch an icon's size (the default).
    case regular
    /// The label in the emphasized body size, the switch an icon's size and a step.
    case large

    public var tunableTitle: String {
        switch self {
        case .compact: "Compact"
        case .regular: "Regular"
        case .large: "Large"
        }
    }
}

nonisolated extension SidebarTunables {
    public static let updateCardAutomaticSize = Tunable<SidebarUpdateToggleSize>.choice(
        "sidebar.updateCard.automaticSize", .sidebar, "Update card Automatic Updates size",
        help: "How big the update card draws its Automatic Updates control: Regular (body text), Large, or the earlier Compact caption size.",
        default: .regular, code: "SidebarTunables.updateCardAutomaticSize")

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
