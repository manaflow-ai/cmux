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

    public static let agentMark = Tunable<SidebarAgentMarkVariant>.choice(
        "sidebar.agentMark", .sidebar, "Agent mark",
        help: "Where a workspace row draws the brand mark of an agent working or waiting in it (R79 prototype).",
        default: .off, code: "SidebarTunables.agentMark")

    public static var all: [TunableDescriptor] {
        [groupEdgeFraction, groupExitFraction, sectionTopFraction].map(\.descriptor) + [agentMark.descriptor] + SidebarSectionTunables.all
    }
}
