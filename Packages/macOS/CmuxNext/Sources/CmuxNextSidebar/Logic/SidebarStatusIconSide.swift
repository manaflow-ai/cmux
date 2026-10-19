public import CmuxNextDesign

/// The side of a sidebar row its status icon sits on with the `status` row badge (Debug Settings
/// `sidebar.statusIconSide`; Leo and Lawrence 2026-10-14, #20900). Left by default (Leo
/// 2026-10-18: a running row's mark on the left); the session rows under a workspace follow it. A
/// Debug choice until it is promoted to Settings.
public nonisolated enum SidebarStatusIconSide: String, Hashable, Sendable, CaseIterable, TunableChoice {
    case left
    case right

    public var tunableTitle: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        }
    }

    public static let tunable = Tunable<SidebarStatusIconSide>.choice(
        "sidebar.statusIconSide", .sidebar, "Status icon side",
        help: "With the Status icon row badge, which side of a sidebar row and of the sessions listed under it shows the status icon (working, needs input, done, error).",
        default: .left, code: "SidebarStatusIconSide.tunable")
}
