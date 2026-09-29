public import CoreGraphics
import Foundation

/// Identity of a rendered row. Views are keyed by this across reloads so
/// moves animate instead of re-creating.
public nonisolated enum SidebarRowKey: Hashable, Sendable {
    case section(SectionID)
    case group(GroupID)
    case workspace(WorkspaceID)
    /// Drop zone shown for an empty section while dragging (pinned area).
    case emptySection(SectionID)
}

/// One laid-out row in document (flipped) coordinates.
public nonisolated struct SidebarRow: Hashable, Sendable {
    public var key: SidebarRowKey
    public var y: CGFloat
    public var height: CGFloat
    public var section: SectionID
    /// Containing group for a workspace row; the group itself for a header.
    public var group: GroupID?
    /// Index among the container's siblings, counting only rows not being
    /// dragged. For group headers this is the group's index in the section.
    public var siblingIndex: Int
    /// For a grouped workspace: the group's index in its section.
    public var parentIndex: Int?
    public var isLastInGroup: Bool
    public var isCollapsed: Bool
    /// Children (groups) or nodes (sections), counting only non-dragged ones.
    public var childCount: Int
    /// Color of the containing group, drawn as a rail beside grouped rows.
    public var groupColor: SidebarColor?

    public var maxY: CGFloat { y + height }
}

/// Row metrics. Values come from CmuxNextDesign `Metrics` tokens; see
/// `standard` and `iconsOnly`. Kept as a plain value so layout stays pure.
public nonisolated struct SidebarLayoutMetrics: Hashable, Sendable {
    public var topPadding: CGFloat
    public var bottomPadding: CGFloat
    public var sectionHeaderHeight: CGFloat
    public var sectionSpacing: CGFloat
    public var groupHeaderHeight: CGFloat
    /// Workspace row with one line.
    public var rowHeight: CGFloat
    /// Workspace row with a subtitle line.
    public var rowHeightWithSubtitle: CGFloat
    public var rowSpacing: CGFloat
    public var groupBottomPadding: CGFloat
    public var emptySectionHeight: CGFloat

    public init(
        topPadding: CGFloat, bottomPadding: CGFloat, sectionHeaderHeight: CGFloat, sectionSpacing: CGFloat,
        groupHeaderHeight: CGFloat, rowHeight: CGFloat, rowHeightWithSubtitle: CGFloat, rowSpacing: CGFloat,
        groupBottomPadding: CGFloat, emptySectionHeight: CGFloat
    ) {
        self.topPadding = topPadding
        self.bottomPadding = bottomPadding
        self.sectionHeaderHeight = sectionHeaderHeight
        self.sectionSpacing = sectionSpacing
        self.groupHeaderHeight = groupHeaderHeight
        self.rowHeight = rowHeight
        self.rowHeightWithSubtitle = rowHeightWithSubtitle
        self.rowSpacing = rowSpacing
        self.groupBottomPadding = groupBottomPadding
        self.emptySectionHeight = emptySectionHeight
    }

    func height(for ws: SidebarWorkspace) -> CGFloat {
        (ws.subtitle ?? "").isEmpty ? rowHeight : rowHeightWithSubtitle
    }
}

/// Inputs that change the layout besides the tree itself./// Inputs that change the layout besides the tree itself.
public nonisolated struct SidebarLayoutOptions: Hashable, Sendable {
    /// Workspaces removed from the layout (being dragged).
    public var excludedWorkspaces: Set<WorkspaceID> = []
    /// A group removed from the layout with its children (being dragged).
    public var excludedGroup: GroupID?
    /// When set, only these workspaces show; containers force-expand.
    public var filterMatches: Set<WorkspaceID>?
    /// Show the drop zone for an empty pinned section.
    public var showEmptyPinned = false
    /// Live gap to open, and its height.
    public var gap: DropPosition?
    public var gapHeight: CGFloat = 0

    public init() {}
}

/// Flattened sidebar: rows with frames, plus the live gap when dragging.
public nonisolated struct SidebarLayout: Hashable, Sendable {
    public var rows: [SidebarRow]
    public var totalHeight: CGFloat
    /// Top of the open gap, if any.
    public var gapY: CGFloat?
    /// Height of the visible gap placeholder.
    public var gapHeight: CGFloat
    /// How far the gap pushes following rows down (height plus spacing).
    /// Pass this to `DropResolver.baseY(forDisplayY:gapY:gapHeight:)`.
    public var gapShift: CGFloat

    public func row(for key: SidebarRowKey) -> SidebarRow? { rows.first { $0.key == key } }

    /// Row whose frame contains `y`, or nil in a gap or padding.
    public func row(at y: CGFloat) -> SidebarRow? { rows.first { y >= $0.y && y < $0.maxY } }

    public static func make(
        sections: [SidebarSection],
        metrics m: SidebarLayoutMetrics,
        options o: SidebarLayoutOptions = SidebarLayoutOptions()
    ) -> SidebarLayout {
        var rows: [SidebarRow] = []
        var y = m.topPadding
        var gapY: CGFloat?
        let filtering = o.filterMatches != nil

        func visible(_ ws: SidebarWorkspace) -> Bool {
            !o.excludedWorkspaces.contains(ws.id) && (o.filterMatches?.contains(ws.id) ?? true)
        }

        func openGapIfNeeded(section: SectionID, group: GroupID?, index: Int) {
            guard gapY == nil, let gap = o.gap, gap.section == section, gap.group == group, gap.index == index else { return }
            gapY = y
            y += o.gapHeight + m.rowSpacing
        }

        var firstSection = true
        for section in sections {
            // Nodes that remain, with their visible children.
            var nodes: [(node: SidebarNode, children: [SidebarWorkspace])] = []
            for node in section.nodes {
                switch node {
                case let .workspace(ws):
                    if visible(ws) { nodes.append((node, [ws])) }
                case let .group(group):
                    if group.id == o.excludedGroup { continue }
                    let children = group.workspaces.filter(visible)
                    // A group emptied by the drag keeps its header (it is a
                    // valid target); a group emptied by the filter hides.
                    if filtering && children.isEmpty { continue }
                    nodes.append((node, children))
                }
            }

            let isPinned = section.id == .pinned
            let gapHere = o.gap?.section == section.id
            if nodes.isEmpty && filtering { continue }
            if isPinned && nodes.isEmpty && !o.showEmptyPinned && !gapHere { continue }

            if !firstSection { y += m.sectionSpacing }
            firstSection = false
            let collapsed = section.isCollapsed && !filtering
            rows.append(SidebarRow(
                key: .section(section.id), y: y, height: m.sectionHeaderHeight, section: section.id,
                group: nil, siblingIndex: 0, parentIndex: nil, isLastInGroup: false,
                isCollapsed: collapsed, childCount: nodes.count, groupColor: nil
            ))
            y += m.sectionHeaderHeight + m.rowSpacing
            if collapsed { continue }

            if nodes.isEmpty {
                if gapHere {
                    openGapIfNeeded(section: section.id, group: nil, index: 0)
                } else {
                    rows.append(SidebarRow(
                        key: .emptySection(section.id), y: y, height: m.emptySectionHeight, section: section.id,
                        group: nil, siblingIndex: 0, parentIndex: nil, isLastInGroup: false,
                        isCollapsed: false, childCount: 0, groupColor: nil
                    ))
                    y += m.emptySectionHeight + m.rowSpacing
                }
                continue
            }

            for (index, entry) in nodes.enumerated() {
                openGapIfNeeded(section: section.id, group: nil, index: index)
                switch entry.node {
                case let .workspace(ws):
                    let h = m.height(for: ws)
                    rows.append(SidebarRow(
                        key: .workspace(ws.id), y: y, height: h, section: section.id,
                        group: nil, siblingIndex: index, parentIndex: nil, isLastInGroup: false,
                        isCollapsed: false, childCount: 0, groupColor: nil
                    ))
                    y += h + m.rowSpacing
                case let .group(group):
                    let groupCollapsed = group.isCollapsed && !filtering
                    rows.append(SidebarRow(
                        key: .group(group.id), y: y, height: m.groupHeaderHeight, section: section.id,
                        group: group.id, siblingIndex: index, parentIndex: nil, isLastInGroup: false,
                        isCollapsed: groupCollapsed, childCount: entry.children.count, groupColor: group.color
                    ))
                    y += m.groupHeaderHeight + m.rowSpacing
                    guard !groupCollapsed else { continue }
                    for (childIndex, ws) in entry.children.enumerated() {
                        openGapIfNeeded(section: section.id, group: group.id, index: childIndex)
                        let h = m.height(for: ws)
                        rows.append(SidebarRow(
                            key: .workspace(ws.id), y: y, height: h, section: section.id,
                            group: group.id, siblingIndex: childIndex, parentIndex: index,
                            isLastInGroup: childIndex == entry.children.count - 1,
                            isCollapsed: false, childCount: 0, groupColor: group.color
                        ))
                        y += h + m.rowSpacing
                    }
                    openGapIfNeeded(section: section.id, group: group.id, index: entry.children.count)
                    y += m.groupBottomPadding
                }
            }
            openGapIfNeeded(section: section.id, group: nil, index: nodes.count)
        }
        y += m.bottomPadding
        return SidebarLayout(
            rows: rows, totalHeight: y, gapY: gapY,
            gapHeight: gapY == nil ? 0 : o.gapHeight,
            gapShift: gapY == nil ? 0 : o.gapHeight + m.rowSpacing
        )
    }
}
