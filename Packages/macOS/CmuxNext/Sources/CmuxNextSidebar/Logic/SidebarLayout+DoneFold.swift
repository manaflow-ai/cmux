import CmuxNextDesign
import CoreGraphics

/// A list's fold: a group's members, or a section's loose rows, that fold behind one row at the list's end.
public nonisolated struct SidebarDoneFoldID: Hashable, Sendable {
    /// What a fold holds.
    public enum Kind: Hashable, Sendable {
        /// Workspaces marked Done: the "Done (N)" row.
        case done
        /// Settled chats (`sidebar.settleFinished`, ``SidebarLayoutOptions/settled``): the "Settled (N)" row, before the
        /// Done row.
        case settled
        /// Archived workspaces: the "Archived (N)" row, after the Done row (Lawrence 18470, gallery pick V2).
        case archived
        /// The Projects list's own "Show N more" row past its first groups (`SidebarLayout+Recents`).
        case projects
    }

    public var section: SectionID
    /// The group whose members fold; nil for the section's loose rows.
    public var group: GroupID?
    /// What the fold holds; ``Kind/done`` by default.
    public var kind: Kind
    /// Group by Folder's folder whose rows fold (only ``Kind/settled`` folds there); nil for every other list.
    public var folder: String?

    public init(section: SectionID, group: GroupID?, kind: Kind = .done, folder: String? = nil) {
        self.section = section
        self.group = group
        self.kind = kind
        self.folder = folder
    }

    /// The Projects list's "Show N more" row (`SidebarLayout+Recents`); its open state is kept with the other lists'.
    public static let projects = SidebarDoneFoldID(section: .pinned, group: nil, kind: .projects)

    /// The same list's fold of `kind`.
    func of(_ kind: Kind) -> SidebarDoneFoldID { SidebarDoneFoldID(section: section, group: group, kind: kind, folder: folder) }
}

nonisolated extension SidebarLayoutOptions {
    /// Whether `ws` draws behind its list's "Settled (N)" row: a settled chat (``settled``), not the active one, and
    /// not while a filter shows matches where they are or the session tree nests rows.
    func settles(_ ws: SidebarWorkspace) -> Bool {
        !settled.isEmpty && settled.contains(ws.id) && ws.id != activeWorkspaceID && filterMatches == nil
            && (sessionTree == nil || sessionTree?.hidesStarted == true)
    }

    /// Clears every fold a drag or an external drop unfolds: Done, Archived and Settled. Archived rows stay
    /// out of the sidebar (``archiveSection``): a drag never draws them back (cmux#51635).
    mutating func unfoldsAll() {
        (foldsDone, foldsArchived) = (false, false)
        settled = []
    }
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
    /// The index `foldingDone` gives the "Settled (N)" row's entry (its depth is the fold's count).
    static let settledFoldIndex = -4

    /// `drawn` with its folds: Rust `sidebar_list_rules` rule `fold` (Done, Settled, Archived and "Show N more" entries
    /// at the list's end). `limits` names the entries the row limit counts and may hide.
    static func foldingDone(_ drawn: [(index: Int, depth: Int)], workspace: (Int) -> SidebarWorkspace?, fold id: SidebarDoneFoldID,
                            limits: (Int) -> Bool = { _ in true }, options o: SidebarLayoutOptions) -> [(index: Int, depth: Int)] {
        guard o.filterMatches == nil else { return drawn }
        let indices = 0..<((drawn.map { $0.index }.max() ?? -1) + 1)
        let rule = ListRule(rule: "fold", drawn: entries(drawn), workspaces: indices.map { workspace($0).map(ListWorkspace.init) },
                            limits: indices.map(limits), options: ListOptions(o, list: id))
        return rules(rule)?.drawn?.map { ($0.index, $0.depth) } ?? drawn
    }

    /// Whether a drag of `dragged` unfolds every list: Rust rule `dragUnfolds`. `workspace` looks up the session tree's
    /// lineage by id.
    static func dragUnfolds(_ dragged: [SidebarWorkspace], workspace: (WorkspaceID) -> SidebarWorkspace? = { _ in nil },
                            options o: SidebarLayoutOptions) -> Bool {
        guard o.foldsDone || o.foldsArchived || o.archiveSection || !o.settled.isEmpty, o.filterMatches == nil else { return false }
        let lineage = Set((o.sessionTree?.parents ?? [:]).flatMap { [$0.key, $0.value] }).sorted { $0.rawValue < $1.rawValue }
        let rule = ListRule(rule: "dragUnfolds", workspaces: lineage.compactMap { workspace($0).map(ListWorkspace.init) },
                            options: ListOptions(o, list: nil, parents: true), dragged: dragged.map(ListWorkspace.init))
        return rules(rule)?.unfolds ?? true
    }

    /// `gapEntry`'s answer when the gap opens after the list's last drawn entry.
    static let gapAtEnd = Int.min

    /// The `drawn` entry a drop gap opens before in a list whose drawn order is not its model order: Rust rule
    /// `gapEntry`. Nil when the list draws in model order or the gap is elsewhere.
    static func gapEntry(_ drawn: [(index: Int, depth: Int)], gap: DropPosition?, section: SectionID, group: GroupID?, count: Int) -> Int? {
        guard let gap else { return nil }
        let rule = ListRule(rule: "gapEntry", drawn: entries(drawn), gap: ListGap(section: "\(gap.section)", group: gap.group?.rawValue, index: gap.index),
                            section: "\(section)", group: group?.rawValue, count: count)
        guard let reply = rules(rule) else { return nil }
        return reply.atEnd == true ? gapAtEnd : reply.entry
    }

    private static func entries(_ drawn: [(index: Int, depth: Int)]) -> [ListEntry] { drawn.map { ListEntry(index: $0.index, depth: $0.depth) } }
    private static func rules(_ rule: ListRule) -> ListReply? { RustSidebarClient.call("sidebar_list_rules", rule, as: ListReply.self) }

    /// Appends the row of a `foldingDone` entry (`doneFoldIndex`, `settledFoldIndex`, `archivedFoldIndex` or `showMoreIndex`) at `y`: one
    /// line, as a document item's row.
    static func appendFold(_ entry: Int, _ list: SidebarDoneFoldID, count: Int, parent: Int?, color: GroupColor?, last: Bool,
                           options o: SidebarLayoutOptions, to rows: inout [SidebarRow], y: inout CGFloat, metrics m: SidebarLayoutMetrics) {
        let more = entry == showMoreIndex
        let id = list.of(entry == archivedFoldIndex ? .archived : entry == settledFoldIndex ? .settled : .done)
        let open = more ? o.openShowMore.contains(id) : o.openDoneFolds.contains(id)
        let content = WorkspaceRowContent()
        let h = m.height(for: content)
        rows.append(SidebarRow(
            key: more ? .showMore(id) : .doneFold(id), y: y, height: h, section: id.section, group: id.group, siblingIndex: 0,
            parentIndex: parent, isLastInGroup: last, isCollapsed: !open, childCount: count, groupColor: color, content: content
        ))
        y += h + m.rowSpacing
    }

    /// The groups a filter keeps for the path to a match: Rust rule `pathToMatch`.
    static func pathToMatch(_ section: SidebarSection, visible: (SidebarWorkspace) -> Bool) -> Set<GroupID> {
        let groups = section.nodes.compactMap { node -> ListMatchGroup? in
            guard case let .group(group) = node else { return nil }
            return ListMatchGroup(id: group.id.rawValue, parent: group.parent?.rawValue, visible: group.workspaces.contains(where: visible))
        }
        guard groups.contains(where: \.visible) else { return [] }
        return Set((rules(ListRule(rule: "pathToMatch", groups: groups))?.path ?? []).map(GroupID.init))
    }
}
