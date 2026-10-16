public import CmuxNextDesign
public import CoreGraphics

/// Debug Settings tunables of sidebar drag and drop (`DropResolver`).
/// Sidebar sizes come from `Metrics` (`MetricTunables`).
public nonisolated enum SidebarTunables {
    public static let groupEdgeFraction = Tunable<CGFloat>.number(
        "sidebar.drop.groupEdgeFraction", .sidebar, "Group header edge share",
        help: "Share of a collapsed group header, from each edge, that drops before or after the group instead of into it.",
        default: 0.25, range: 0...0.5, step: 0.01, unit: .fraction, code: "SidebarTunables.groupEdgeFraction")
    public static let groupExitFraction = Tunable<CGFloat>.number(
        "sidebar.drop.groupExitFraction", .sidebar, "Group exit share",
        help: "Lower share of a group's last row that drops after the group.",
        default: 0.25, range: 0...0.5, step: 0.01, unit: .fraction, code: "SidebarTunables.groupExitFraction")
    public static let sectionTopFraction = Tunable<CGFloat>.number(
        "sidebar.drop.sectionTopFraction", .sidebar, "Section header top share",
        help: "Upper share of a section header that drops at the end of the previous section.",
        default: 0.35, range: 0...0.8, step: 0.01, unit: .fraction, code: "SidebarTunables.sectionTopFraction")
    public static let workspaceOntoStart = Tunable<CGFloat>.number(
        "sidebar.drop.workspaceOntoStart", .sidebar, "Group-on-drop band start",
        help: "Where the middle band of a loose workspace row starts; a drop in the band groups the two workspaces.",
        default: 0.3, range: 0...0.5, step: 0.01, unit: .fraction, code: "SidebarTunables.workspaceOntoStart")
    public static let workspaceOntoEnd = Tunable<CGFloat>.number(
        "sidebar.drop.workspaceOntoEnd", .sidebar, "Group-on-drop band end",
        help: "Where the middle band of a loose workspace row ends. Equal to the start turns grouping on drop off.",
        default: 0.7, range: 0.5...1, step: 0.01, unit: .fraction, code: "SidebarTunables.workspaceOntoEnd")

    public static let agentMark = Tunable<SidebarAgentMarkVariant>.choice(
        "sidebar.agentMark", .sidebar, "Agent mark",
        help: "Where a workspace row draws the brand mark of an agent running in it (R79 prototype).",
        default: .off, code: "SidebarTunables.agentMark")

    /// Multiplayer agent presence (cx-gg84): off until the dots are styled
    /// into the row; the daemon feed (`agent-presence-v1`) runs either way.
    public static let presenceDots = Tunable<Bool>.toggle(
        "sidebar.presenceDots", .sidebar, "Agent presence dots",
        help: "A round dot per agent acting right now, in the agent's theme color: on its workspace row (hover lists what each one touches) and on its tab chip (prototype).",
        default: false, code: "SidebarTunables.presenceDots")

    /// Rows show their agent sessions' acpmux lane state (`SidebarLaneStatus`): working, waiting
    /// on you, failed, idle, even when no turn state reached the row. Off by default.
    public static let laneStatus = Tunable<Bool>.toggle(
        "sidebar.laneStatus", .sidebar, "Rows show acpmux lane status",
        help: "A workspace row's status mark also follows the acpmux lane of each agent chat in it on this Mac: waiting on you or failed wins, then working, then the row's own status.",
        default: false, code: "SidebarTunables.laneStatus")

    /// Sample rows with 1 to 7 pending items (`SidebarSection.rowBadgePreview()`).
    public static let rowBadgePreview = Tunable<Bool>.toggle(
        "sidebar.rowBadgePreview", .sidebar, "Row badge preview rows",
        help: "Adds sample rows with 1 to 7 pending items to the sidebar, to compare the row badges without real sessions.",
        default: false, code: "SidebarTunables.rowBadgePreview")

    public static var all: [TunableDescriptor] {
        [groupEdgeFraction, groupExitFraction, sectionTopFraction, workspaceOntoStart, workspaceOntoEnd].map(\.descriptor) + [agentMark.descriptor, presenceDots.descriptor, SidebarRowBadgeStyle.tunable.descriptor, SidebarRowBadgeStackCap.tunable.descriptor, rowBadgePreview.descriptor, NotificationBadgeLook.tunable.descriptor, NotificationIconLook.tunable.descriptor, updateCardButton.descriptor, SidebarChatsDesign.tunable.descriptor] + SidebarSectionTunables.all + [laneStatus.descriptor]
    }
}
