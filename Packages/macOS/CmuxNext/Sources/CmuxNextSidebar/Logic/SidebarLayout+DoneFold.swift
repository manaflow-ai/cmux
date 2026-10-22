import CmuxNextDesign
import CoreGraphics

/// A list that folds its workspaces marked Done: a group's members, or a section's loose rows.
public nonisolated struct SidebarDoneFoldID: Hashable, Sendable {
    public var section: SectionID
    /// The group whose members fold; nil for the section's loose rows.
    public var group: GroupID?

    public init(section: SectionID, group: GroupID?) {
        self.section = section
        self.group = group
    }
}

// The "Done (N)" fold (`sidebar.doneFold`, Leo's sidebar organization): workspaces the person marked Done
// (`SidebarTaskStatus.done`) leave their place and list behind one row at the end of their group or list, in their
// manual order; the row opens them below it. The model's order never changes: only the drawn order does.
nonisolated extension SidebarLayout {
    /// The index `foldingDone` gives the fold's own entry (its depth is the fold's count).
    static let doneFoldIndex = -1

    /// `drawn` with the workspaces marked Done moved behind one fold entry (`doneFoldIndex`) at the end, and after it
    /// when the person opened the fold. Unchanged when the fold is off, while filtering (a match shows where it is),
    /// with the session tree (it nests rows under others), or with nothing Done. The active workspace keeps its place.
    static func foldingDone(_ drawn: [(index: Int, depth: Int)], workspace: (Int) -> SidebarWorkspace?, fold id: SidebarDoneFoldID,
                            options o: SidebarLayoutOptions) -> [(index: Int, depth: Int)] {
        guard o.foldsDone, o.filterMatches == nil, o.sessionTree == nil else { return drawn }
        var shown: [(index: Int, depth: Int)] = []
        var done: [(index: Int, depth: Int)] = []
        for entry in drawn {
            if let ws = workspace(entry.index), ws.taskStatus == .done, ws.id != o.activeWorkspaceID { done.append(entry) } else { shown.append(entry) }
        }
        guard !done.isEmpty else { return drawn }
        return shown + [(doneFoldIndex, done.count)] + (o.openDoneFolds.contains(id) ? done : [])
    }

    /// Appends the fold's "Done (N)" row at `y`: one line, as a document item's row.
    static func appendDoneFold(_ id: SidebarDoneFoldID, count: Int, open: Bool, parent: Int?, color: GroupColor?, last: Bool,
                               to rows: inout [SidebarRow], y: inout CGFloat, metrics m: SidebarLayoutMetrics) {
        let content = WorkspaceRowContent()
        let h = m.height(for: content)
        rows.append(SidebarRow(
            key: .doneFold(id), y: y, height: h, section: id.section, group: id.group, siblingIndex: 0, parentIndex: parent,
            isLastInGroup: last, isCollapsed: !open, childCount: count, groupColor: color, content: content
        ))
        y += h + m.rowSpacing
    }

    /// The groups a filter keeps for the path to a match (remote-groups-DESIGN.md slice 2): every group above a group
    /// with a visible workspace.
    static func pathToMatch(_ section: SidebarSection, visible: (SidebarWorkspace) -> Bool) -> Set<GroupID> {
        var path = Set<GroupID>()
        let parents = Dictionary(section.nodes.compactMap { node -> (GroupID, GroupID?)? in
            if case let .group(group) = node { (group.id, group.parent) } else { nil }
        }, uniquingKeysWith: { first, _ in first })
        for node in section.nodes {
            guard case let .group(group) = node, group.workspaces.contains(where: visible) else { continue }
            var parent = group.parent
            while let id = parent, path.insert(id).inserted { parent = parents[id] ?? nil }
        }
        return path
    }
}
