import CmuxNextDesign
import CoreGraphics

/// A list's fold: a group's members, or a section's loose rows, that fold behind one row at the list's end.
public nonisolated struct SidebarDoneFoldID: Hashable, Sendable {
    /// What a fold holds.
    public enum Kind: Hashable, Sendable {
        /// Workspaces marked Done: the "Done (N)" row.
        case done
        /// Archived workspaces: the "Archived (N)" row, after the Done row (Lawrence 18470, gallery pick V2).
        case archived
        /// The sidebar's one Archive section (``SidebarDoneFoldID/archive``): every archived workspace and wholly
        /// archived group, under one "Archive (N)" row at the bottom (Lawrence 19197).
        case archive
        /// The Projects list's own "Show N more" row past its first groups (`SidebarLayout+Recents`).
        case projects
    }

    public var section: SectionID
    /// The group whose members fold; nil for the section's loose rows.
    public var group: GroupID?
    /// What the fold holds; ``Kind/done`` by default.
    public var kind: Kind

    public init(section: SectionID, group: GroupID?, kind: Kind = .done) {
        self.section = section
        self.group = group
        self.kind = kind
    }

    /// The bottom "Archive (N)" row (`SidebarLayout+ArchiveSection`); its open state is kept with the folds'.
    public static let archive = SidebarDoneFoldID(section: .pinned, group: nil, kind: .archive)

    /// The Projects list's "Show N more" row (`SidebarLayout+Recents`); its open state is kept with the other lists'.
    public static let projects = SidebarDoneFoldID(section: .pinned, group: nil, kind: .projects)

    /// The same list's fold of `kind`.
    func of(_ kind: Kind) -> SidebarDoneFoldID { SidebarDoneFoldID(section: section, group: group, kind: kind) }
}

// The "Done (N)" fold (Leo's sidebar organization): workspaces the person marked Done
// (`SidebarTaskStatus.done`) leave their place and list behind one row at the end of their group or list, in their
// manual order; the row opens them below it. Archived workspaces (`isArchived`, `foldsArchived`) do the same behind an
// "Archived (N)" row after it (Lawrence 18470: "better ui for archived stuff instead of just greying them out"; it
// took a dimmed row each). The model's order never changes: only the drawn order does.
nonisolated extension SidebarLayout {
    /// The index `foldingDone` gives the "Done (N)" row's entry (its depth is the fold's count).
    static let doneFoldIndex = -1
    /// The index `foldingDone` gives the "Show N more" row's entry (its depth is the count; 0 once opened: "Show fewer").
    static let showMoreIndex = -2
    /// The index `foldingDone` gives the "Archived (N)" row's entry (its depth is the fold's count).
    static let archivedFoldIndex = -3

    /// `drawn` with the workspaces marked Done moved behind one fold entry (`doneFoldIndex`) at the end, and after it
    /// when the person opened the fold; then, past `rowLimit`, the rest behind a "Show N more" entry (`limiting`).
    /// Unchanged while filtering (a match shows where it is) or with the session tree (it nests rows under others).
    /// The active workspace keeps its place.
    /// `limits` names the entries the limit counts and may hide: a section's groups and items always show.
    static func foldingDone(_ drawn: [(index: Int, depth: Int)], workspace: (Int) -> SidebarWorkspace?, fold id: SidebarDoneFoldID,
                            limits: (Int) -> Bool = { _ in true }, project: SidebarGroup? = nil,
                            options o: SidebarLayoutOptions) -> [(index: Int, depth: Int)] {
        guard o.filterMatches == nil, o.sessionTree == nil else { return drawn }
        var shown: [(index: Int, depth: Int)] = []
        var done: [(index: Int, depth: Int)] = []
        var archived: [(index: Int, depth: Int)] = []
        for entry in drawn {
            let ws = workspace(entry.index)
            if o.foldsArchived, let ws, ws.isArchived, ws.id != o.activeWorkspaceID {
                archived.append(entry)
            } else if o.foldsDone, let ws, ws.taskStatus == .done, ws.id != o.activeWorkspaceID {
                done.append(entry)
            } else {
                shown.append(entry)
            }
        }
        var listed = limiting(shown, workspace: workspace, limits: limits, list: id, project: project, options: o)
        if !done.isEmpty { listed += [(doneFoldIndex, done.count)] + (o.openDoneFolds.contains(id.of(.done)) ? done : []) }
        if !archived.isEmpty {
            listed += [(archivedFoldIndex, archived.count)] + (o.openDoneFolds.contains(id.of(.archived)) ? archived : [])
        }
        return listed
    }

    /// The cap, the revealed rows and the floating that decide list `id`'s rows: a project's (a group's own cap, else
    /// Chats per Project), or a loose list's (only the Debug `rowLimit`, never floating: the top level keeps the order the
    /// person gave it). Nil when the list shows every row in place.
    static func caps(list id: SidebarDoneFoldID, project: SidebarGroup?, options o: SidebarLayoutOptions) -> RustSidebarCaps.Caps? {
        let cap = o.rowLimit > 0 ? o.rowLimit : project.map { $0.rowLimit ?? o.projectCap } ?? 0
        let floats = project != nil && o.floatsInProject
        guard cap > 0 || floats else { return nil }
        return RustSidebarCaps.Caps(cap: cap, revealed: o.revealed[id] ?? project?.revealed ?? 0, floats: floats,
                                    includeWorking: o.includesWorking)
    }

    /// `shown` under its list's caps (Leo 2026-11-10, design/sidebar.md "Per-project caps"): the pinned rows, then yellow
    /// and blue risen to the top of the project, then the first quiet rows in place with every active one (running, the
    /// selected row, a row the limit does not count), then a "Show N more" entry (its depth is how many one press shows)
    /// or, revealed to the end, "Show less" (depth 0). Rust decides (`RustSidebarCaps`); Swift passes the length and the
    /// active rows only, so the cost is the rows drawn, not the rows hidden.
    private static func limiting(_ shown: [(index: Int, depth: Int)], workspace: (Int) -> SidebarWorkspace?, limits: (Int) -> Bool,
                                 list id: SidebarDoneFoldID, project: SidebarGroup?, options o: SidebarLayoutOptions) -> [(index: Int, depth: Int)] {
        guard let caps = caps(list: id, project: project, options: o) else { return shown }
        var active: [(position: Int, flags: RustSidebarCaps.Flags)] = []
        for (position, entry) in shown.enumerated() {
            guard limits(entry.index), let ws = workspace(entry.index) else {
                active.append((position, .keep)) // a group, an item: always drawn, in place
                continue
            }
            var flags = RustSidebarCaps.Flags.of(ws)
            if ws.id == o.activeWorkspaceID { flags.insert(.keep) }
            if project?.pinnedMembers.contains(ws.id) == true { flags.insert(.pinned) }
            if !flags.isEmpty { active.append((position, flags)) }
        }
        guard let answer = RustSidebarCaps.project(count: shown.count, active: active, caps: caps) else { return shown }
        var listed = answer.rows.map { shown[$0] }
        switch answer.tail {
        case .none: break
        case let .showMore(_, next): listed.append((showMoreIndex, next))
        case .showLess: listed.append((showMoreIndex, 0))
        }
        return listed
    }

    /// Whether a drag of `dragged` unfolds every list: it carries a row the fold would hide or draw below it (marked
    /// Done, not the active one). Such a row would leave its slot (`displayLayout` slides the dragged rows as one), or
    /// make or drop a "Done (N)" row the drag's base rows lack, so the drag draws as it did before it kept the folds.
    /// A drag of rows that never fold keeps them: it moves no fold row and changes no fold's count.
    static func dragUnfolds(_ dragged: [SidebarWorkspace], options o: SidebarLayoutOptions) -> Bool {
        guard o.foldsDone || o.foldsArchived || o.archiveSection, o.filterMatches == nil, o.sessionTree == nil else { return false }
        return dragged.contains {
            $0.id != o.activeWorkspaceID
                && ((o.foldsDone && $0.taskStatus == .done) || ((o.foldsArchived || o.archiveSection) && $0.isArchived))
        }
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

    /// Appends the row of a `foldingDone` entry (`doneFoldIndex`, `archivedFoldIndex` or `showMoreIndex`) at `y`: one
    /// line, as a document item's row.
    static func appendFold(_ entry: Int, _ list: SidebarDoneFoldID, count: Int, parent: Int?, color: GroupColor?, last: Bool,
                           options o: SidebarLayoutOptions, to rows: inout [SidebarRow], y: inout CGFloat, metrics m: SidebarLayoutMetrics) {
        let more = entry == showMoreIndex
        let id = list.of(entry == archivedFoldIndex ? .archived : .done)
        // "Show N more" carries how many one press reveals; 0 is "Show less" (`limiting`).
        let open = more ? count == 0 : o.openDoneFolds.contains(id)
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
