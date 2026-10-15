/// The side of a workspace row and a tab its status icon sits on when the row badge style is
/// `status` (Debug Settings `sidebar.statusIconSide`; Leo and Lawrence 2026-10-14). A Debug choice
/// until it is promoted to Settings.
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
        help: "With the Status icon row badge, which side of a sidebar row and a tab shows its status icon (working, needs input, done, error).",
        default: .left, code: "SidebarStatusIconSide.tunable")
}
