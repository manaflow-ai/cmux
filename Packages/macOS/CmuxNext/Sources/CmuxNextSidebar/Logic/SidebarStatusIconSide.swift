public import CmuxNextDesign

/// The side of a sidebar row its status icon sits on with the `status` row badge (Debug Settings
/// `sidebar.statusIconSide`; Leo and Lawrence 2026-10-14, #20900). Right by default: "Nothing should
/// ever be on the left side besides the favicon" (Lawrence 2026-10-19, 57997c32). Left is Leo's
/// running mark before the title (2026-10-18), kept as the Debug choice. The session rows under a
/// workspace follow it.
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
        default: .right, code: "SidebarStatusIconSide.tunable")
}
