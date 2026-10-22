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
    /// The index `foldingDone` gives the "Done (N)" row's entry (its depth is the fold's count).
    static let doneFoldIndex = -1
    /// The index `foldingDone` gives the "Show N more" row's entry (its depth is the count; 0 once opened: "Show fewer").
    static let showMoreIndex = -2

    /// `drawn` with the workspaces marked Done moved behind one fold entry (`doneFoldIndex`) at the end, and after it
    /// when the person opened the fold; then, past `rowLimit`, the rest behind a "Show N more" entry (`limiting`).
    /// Unchanged while filtering (a match shows where it is) or with the session tree (it nests rows under others).
    /// The active workspace keeps its place.
    /// `limits` names the entries the limit counts and may hide: a section's groups and items always show.
    static func foldingDone(_ drawn: [(index: Int, depth: Int)], workspace: (Int) -> SidebarWorkspace?, fold id: SidebarDoneFoldID,
                            limits: (Int) -> Bool = { _ in true }, options o: SidebarLayoutOptions) -> [(index: Int, depth: Int)] {
        guard o.filterMatches == nil, o.sessionTree == nil else { return drawn }
        var shown: [(index: Int, depth: Int)] = []
        var done: [(index: Int, depth: Int)] = []
        for entry in drawn {
            if o.foldsDone, let ws = workspace(entry.index), ws.taskStatus == .done, ws.id != o.activeWorkspaceID {
                done.append(entry)
            } else {
                shown.append(entry)
            }
        }
        let listed = limiting(shown, workspace: workspace, limits: limits, list: id, options: o)
        guard !done.isEmpty else { return listed }
        return listed + [(doneFoldIndex, done.count)] + (o.openDoneFolds.contains(id) ? done : [])
    }

    /// `shown` past `rowLimit` rows (`sidebar.groupRowLimit`): the first ones, those that need you and the active one,
    /// then a "Show N more" entry for the rest; opened, every row then a "Show fewer" entry. A list one row over the
    /// limit shows whole: a row that hides one row saves nothing.
    private static func limiting(_ shown: [(index: Int, depth: Int)], workspace: (Int) -> SidebarWorkspace?, limits: (Int) -> Bool,
                                 list id: SidebarDoneFoldID, options o: SidebarLayoutOptions) -> [(index: Int, depth: Int)] {
        let limited = shown.filter { limits($0.index) }.count
        guard o.rowLimit > 0, limited > o.rowLimit + 1 else { return shown }
        if o.openShowMore.contains(id) { return shown + [(showMoreIndex, 0)] }
        var kept: [(index: Int, depth: Int)] = []
        var n = 0
        for entry in shown {
            guard limits(entry.index) else { kept.append(entry); continue }
            let stays = workspace(entry.index).map { $0.id == o.activeWorkspaceID || $0.agentChip == .needsYou } ?? false
            if n < o.rowLimit || stays { kept.append(entry) }
            n += 1
        }
        return kept.count == shown.count ? shown : kept + [(showMoreIndex, shown.count - kept.count)]
    }

    /// Whether a drag of `dragged` unfolds every list: it carries a row the fold would hide or draw below it (marked
    /// Done, not the active one). Such a row would leave its slot (`displayLayout` slides the dragged rows as one), or
    /// make or drop a "Done (N)" row the drag's base rows lack, so the drag draws as it did before it kept the folds.
    /// A drag of rows that never fold keeps them: it moves no fold row and changes no fold's count.
    static func dragUnfolds(_ dragged: [SidebarWorkspace], options o: SidebarLayoutOptions) -> Bool {
        guard o.foldsDone, o.filterMatches == nil, o.sessionTree == nil else { return false }
        return dragged.contains { $0.taskStatus == .done && $0.id != o.activeWorkspaceID }
    }

    /// The `drawn` entry a drop gap opens before in a list that draws a fold (a drag keeps the folds): the first row
    /// drawn before the fold whose model index is at or past the gap's, else the fold row. That is where the dropped
    /// row (never Done) will show: a hidden index between two drawn rows, the list's end, and, with the fold open, an
    /// index of a Done row drawn below the fold all open the gap among the rows above it. Nil when the list draws no
    /// fold or the gap is elsewhere (`openGapIfNeeded` places it as before).
    static func gapEntry(_ drawn: [(index: Int, depth: Int)], gap: DropPosition?, section: SectionID, group: GroupID?, count: Int) -> Int? {
        guard let gap, gap.section == section, gap.group == group, gap.index <= count, drawn.contains(where: { $0.index < 0 }) else { return nil }
        // Shown rows come first in model order, then the fold rows and an open fold's Done rows (`foldingDone`).
        return drawn.first { $0.index < 0 || $0.index >= gap.index }?.index
    }

    /// Appends the row of a `foldingDone` entry (`doneFoldIndex` or `showMoreIndex`) at `y`: one line, as a document
    /// item's row.
    static func appendFold(_ entry: Int, _ id: SidebarDoneFoldID, count: Int, parent: Int?, color: GroupColor?, last: Bool,
                           options o: SidebarLayoutOptions, to rows: inout [SidebarRow], y: inout CGFloat, metrics m: SidebarLayoutMetrics) {
        let more = entry == showMoreIndex
        let open = more ? o.openShowMore.contains(id) : o.openDoneFolds.contains(id)
        let content = WorkspaceRowContent()
        let h = m.height(for: content)
        rows.append(SidebarRow(
            key: more ? .showMore(id) : .doneFold(id), y: y, height: h, section: id.section, group: id.group, siblingIndex: 0,
            parentIndex: parent, isLastInGroup: last, isCollapsed: !open, childCount: count, groupColor: color, content: content
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
