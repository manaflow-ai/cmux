/// SIDEBAR ROW CHANGE stage 2: one loose workspace row gone from a window's list or new in it, as the INPUT of the
/// model and the list (Chromium's `TabStripModelChange`: the strip gets the change with its index and lays out from
/// it; it never finds the change by a compare of the old tabs and the new ones). `SidebarModel.setSections` took the
/// whole new list and found the one row by reading every listed row several times (826 workspaces: 1688 rows read per
/// close after stage 1).
///
/// `section` and `node` name the row's place in the rows the caller gave to the last `SidebarModel.setSections`, as
/// they are after the changes the model took since. The model takes a change only while it knows its own place for
/// that node: its rows are the caller's (no hidden node), or a sidebar document arranged them and took nothing but
/// band groups out of that machine list (`SidebarRowChangeBase.leftOut`).
public nonisolated enum SidebarLooseRowChange: Sendable, Equatable {
    /// The loose row of workspace `id`, node `node` of `section`, left the list. Every other row stays.
    case removed(WorkspaceID, section: SectionID, node: Int)
    /// `workspace`'s loose row is new at node `node` of `section`. Every other row stays.
    case added(SidebarWorkspace, section: SectionID, node: Int)
}

/// What the last full set (`SidebarModel.setSections`) knows for `SidebarModel.apply(_:)`: where the model's rows
/// sit against the caller's places, which sidebar document arranged them, and how many times they list each
/// workspace. The full set counts the listings (one more read of each row in a set that reads each row several
/// times); each one-row change keeps the count and the places in step.
nonisolated struct SidebarRowChangeBase: Sendable {
    /// The hidden items of the last full set: a change of them hides other nodes.
    private(set) var hidden: Set<LayoutItemRef> = []
    /// For each section of the caller's rows whose nodes the model shows in the caller's order: the caller's nodes
    /// that the model's section leaves out, ascending. With no document that is none (and every section, or no
    /// section when one differs: a hidden item takes a node out). Under a sidebar document they are the band groups
    /// it lists in their own sections; only a machine list whose order the document keeps has an entry. A section
    /// with no entry takes no change. Nil: no section does.
    private(set) var leftOut: [SectionID: [Int]]?
    /// The document store that arranged the last full set, and its `SidebarDocStore.shownChanges` and group folds
    /// then; `document` nil: no document arranged it. A change is taken only while they are the same: what the
    /// document arranges is then what it arranged.
    private(set) var document: ObjectIdentifier?
    private(set) var documentChanges: UInt64 = 0
    private(set) var folds: [String: Bool] = [:]
    /// At least one section takes changes.
    var samePlaces: Bool { !(leftOut?.isEmpty ?? true) }
    /// How many times the rows list each workspace (loose or in a group). Nil: not counted, no change is taken.
    private(set) var listings: [WorkspaceID: Int]?
    /// The workspaces listed more than once: the list draws one row for each, so its rows are not the model's.
    private(set) var repeated = 0
    /// The model's `structureRevision` that `listings` counts: another structural write leaves them behind.
    private(set) var structure: UInt64 = 0

    /// A full set of `given`, which the model shows as `shown`. `document`: the store whose document arranged it
    /// (nil: none), at `changes` and `folds`; `kept`: the sections whose order it keeps (a machine list that it does
    /// not place by its own order and that is no host group).
    mutating func note(given: [SidebarSection], shown: [SidebarSection], hidden: Set<LayoutItemRef>, document: ObjectIdentifier?,
                       changes: UInt64, folds: [String: Bool], kept: Set<SectionID>) {
        self.hidden = hidden
        self.document = document
        documentChanges = changes
        self.folds = folds
        guard document != nil else {
            let same = given.count == shown.count && zip(given, shown).allSatisfy { $0.id == $1.id && $0.nodes.count == $1.nodes.count }
            leftOut = same ? Dictionary(given.map { ($0.id, [Int]()) }, uniquingKeysWith: { first, _ in first }) : nil
            return
        }
        // What `SidebarDocProjection.arrange` does to a kept section: it takes the band groups out and changes no
        // other node's place. The walk proves that for this set.
        var places: [SectionID: [Int]] = [:]
        var seen: Set<SectionID> = []
        for section in given {
            guard seen.insert(section.id).inserted else { // the same section twice: neither takes a change
                places[section.id] = nil
                continue
            }
            guard kept.contains(section.id), let s = shown.firstIndex(where: { $0.id == section.id }),
                  shown.lastIndex(where: { $0.id == section.id }) == s else { continue }
            SidebarPerfCounters.add(.rowListingReads, section.nodes.count) // each node's identity, once per full set
            places[section.id] = Self.nodesLeftOut(of: section.nodes, in: shown[s].nodes)
        }
        leftOut = places
    }

    /// The indexes of `given` that `shown` leaves out, when `shown` is `given` in its order without some of its
    /// groups; nil when it is anything else (a hidden item, a link row put in, another order).
    private static func nodesLeftOut(of given: [SidebarNode], in shown: [SidebarNode]) -> [Int]? {
        var out: [Int] = []
        var at = 0
        for (index, node) in given.enumerated() {
            if at < shown.count, shown[at].id == node.id {
                at += 1
            } else if case .group = node {
                out.append(index)
            } else {
                return nil
            }
        }
        return at == shown.count ? out : nil
    }

    /// The model's node for the caller's node `node` of `section`: the left-out nodes before it do not count. Nil
    /// when the section takes no change, or when the node is a left-out one and no new row comes in before it.
    func place(of node: Int, in section: SectionID, inserting: Bool) -> Int? {
        guard node >= 0, let out = leftOut?[section] else { return nil }
        var before = 0
        for index in out {
            if index < node {
                before += 1
            } else if index == node, !inserting {
                return nil
            } else {
                break
            }
        }
        return node - before
    }

    /// Counts the listings of `sections` (the model's rows at `structure`) unless they are counted already.
    mutating func recount(_ sections: [SidebarSection], structure: UInt64) {
        guard samePlaces else { // no change is taken: no count
            listings = nil
            return
        }
        guard listings == nil || self.structure != structure else { return }
        var counts: [WorkspaceID: Int] = [:]
        var repeated = 0
        for section in sections {
            for node in section.nodes {
                for ws in node.workspaces {
                    let seen = counts[ws.id, default: 0]
                    if seen == 1 { repeated += 1 }
                    counts[ws.id] = seen + 1
                }
            }
        }
        SidebarPerfCounters.add(.rowListingReads, counts.count) // every listed workspace, once per structural full set
        listings = counts
        self.repeated = repeated
        self.structure = structure
    }

    /// A one-row change the model took at the caller's node `node` of `section`: `id` is listed once now (`listed`)
    /// or not at all, at `structure`, and the left-out nodes after the place moved by one in the caller's rows.
    mutating func took(_ id: WorkspaceID, listed: Bool, section: SectionID, node: Int, structure: UInt64) {
        listings?[id] = listed ? 1 : nil
        self.structure = structure
        guard let out = leftOut?[section], !out.isEmpty else { return }
        leftOut?[section] = out.map { index in listed ? (index >= node ? index + 1 : index) : (index > node ? index - 1 : index) }
    }
}

extension SidebarModel {
    /// Whether the model takes a one-row change now: it knows its place for the caller's nodes of at least one
    /// section (the last full set hid no node, or a sidebar document arranged it and kept that machine list's order;
    /// nothing wrote the structure since), no workspace is listed twice, no filter or hidden-item change decides
    /// which rows show, and the document that arranges the list is the one of the last full set, unchanged.
    /// O(sections + the document's groups).
    ///
    /// The caller's part: the window facts the arrangement reads beside the document (`SidebarDocDrag.listedElsewhere`,
    /// `room`, `spaces`) have no change counter here, so a caller sets the sections when one of them changed
    /// (`SidebarRows.show` does, by its `elsewhere` and visibility compares).
    public var takesRowChanges: Bool {
        // Read in place: a copy of the base held over a change would make its count copy itself (every workspace).
        guard rowChangeBase.samePlaces, rowChangeBase.listings != nil, rowChangeBase.repeated == 0,
              rowChangeBase.structure == structureRevision, filterText.isEmpty, splicesRemovals,
              hiddenItemRefs == rowChangeBase.hidden, arrangesAsTheLastFullSet else { return false }
        // A full set folds each section as the window has it: a section that it would fold or open is more than one row.
        return !storedSections.contains { $0.isCollapsed != collapsedSections.contains($0.id) }
    }

    /// Shows `change` as `setSections` shows the same rows without the row, or with it: the one node goes out of its
    /// section or comes in (at the model's place for the caller's node, past the band groups a document took out),
    /// the revisions move as a structural set moves them, and the list gets the row as `rowRemoval` or
    /// `rowInsertion`. No other row is read. False, with nothing changed, when the model can not prove that
    /// (`takesRowChanges`, a section the document orders or wraps, a row that is not a loose row at that place, a
    /// workspace listed elsewhere): the caller then sets the sections.
    ///
    /// Not constant, and not counted by `rows_walked`: the array's own move of the nodes after the place (and one copy
    /// of that section's node buffer while the list or a record holds it), the shift of that section's group lookups
    /// (one per listed group), and the row index and the workspace order, which the next reader builds again as after
    /// any structural set (`row_index_builds`, `order_builds`).
    // perf-hot: 0.1ms workspace-list-change
    @discardableResult
    public func apply(_ change: SidebarLooseRowChange) -> Bool {
        guard takesRowChanges else { return false }
        let from = sectionsRevision
        switch change {
        case let .removed(id, section, node):
            guard let s = uniqueSection(section), let at = rowChangeBase.place(of: node, in: section, inserting: false),
                  storedSections[s].nodes.indices.contains(at),
                  case let .workspace(ws) = storedSections[s].nodes[at], ws.id == id, rowChangeBase.listings?[id] == 1 else { return false }
            writeRowChange(section: s, node: at, inserting: nil)
            rowChangeBase.took(id, listed: false, section: section, node: node, structure: structureRevision)
            rowInsertion = nil
            rowRemoval = SidebarRowRemoval(from: from, to: sectionsRevision, content: contentRevision, section: storedSections[s], node: at,
                                           workspace: ws, insertion: nil, fromRowChange: true)
        case let .added(given, section, node):
            guard let s = uniqueSection(section), let at = rowChangeBase.place(of: node, in: section, inserting: true),
                  at <= storedSections[s].nodes.count, rowChangeBase.listings?[given.id] == nil else { return false }
            let ws = arrangedRow(given)
            writeRowChange(section: s, node: at, inserting: ws)
            rowChangeBase.took(ws.id, listed: true, section: section, node: node, structure: structureRevision)
            rowInsertion = SidebarRowInsertion(from: from, to: sectionsRevision, content: contentRevision, section: storedSections[s], node: at,
                                               fromRowChange: true)
            rowRemoval = nil
        }
        SidebarPerfCounters.add(.rowChanges)
        SidebarPerfCounters.add(.rowsWalked) // the changed row
        return true
    }

    /// Tells the base of a full set of `given`, which the model shows as `shown`: the hidden items, and the sidebar
    /// document that arranged it (its store, `shownChanges` and folds) with the sections whose order it keeps: a
    /// machine list that it does not place by its own order (`SidebarDocProjection.keepsMappedOrder`) and that is no
    /// host group, given or shown.
    func noteFullSet(given: [SidebarSection], shown: [SidebarSection]) {
        var document: ObjectIdentifier?
        var changes: UInt64 = 0
        var folds: [String: Bool] = [:]
        var kept: Set<SectionID> = []
        if let drag = docDrag, let store = drag.document, let projection = store.shown {
            document = ObjectIdentifier(store)
            changes = store.shownChanges
            folds = store.groupFolds
            for section in given where section.machine != nil && !section.isHostGroup && !section.drawsAsGroup {
                if projection.keepsMappedOrder(of: section.id, drag: drag) { kept.insert(section.id) }
            }
            for section in shown where section.isHostGroup || section.drawsAsGroup { kept.remove(section.id) }
        }
        rowChangeBase.note(given: given, shown: shown, hidden: hiddenItemRefs, document: document, changes: changes, folds: folds, kept: kept)
    }

    /// Whether the sidebar document that arranges the list now is the one of the last full set with no change since
    /// (the same store, `SidebarDocStore.shownChanges` and group folds), or none arranged it and none does now.
    private var arrangesAsTheLastFullSet: Bool {
        guard let store = docDrag?.document, store.shown != nil else { return rowChangeBase.document == nil }
        return rowChangeBase.document == ObjectIdentifier(store) && rowChangeBase.documentChanges == store.shownChanges
            && rowChangeBase.folds == store.groupFolds
    }

    /// `workspace` as the document's arrangement shows a loose row: marked archived by the document, as
    /// `SidebarDocProjection.arrange` marks each row; itself when no document arranges the list.
    private func arrangedRow(_ workspace: SidebarWorkspace) -> SidebarWorkspace {
        guard let drag = docDrag, let shown = drag.document?.shown else { return workspace }
        var workspace = workspace
        workspace.isArchived = drag.item(.workspace(workspace.id)).map { shown.archived.contains($0) } ?? false
        return workspace
    }

    /// The index of the one stored section with `id`; nil when none or more than one has it.
    private func uniqueSection(_ id: SectionID) -> Int? {
        guard let s = storedSections.firstIndex(where: { $0.id == id }), storedSections.lastIndex(where: { $0.id == id }) == s else { return nil }
        return s
    }

    /// Takes node `node` out of stored section `s`, or puts `inserting`'s loose row in there, as one structural set:
    /// one write of the rows (`contentRevision` moves once), the lookups of the groups after the place follow, and
    /// `sectionsRevision` and `structureRevision` move once, told to the observers of `sections`.
    private func writeRowChange(section s: Int, node: Int, inserting: SidebarWorkspace?) {
        withMutation(keyPath: \.sections) {
            if let inserting {
                storedSections[s].nodes.insert(.workspace(inserting), at: node)
            } else {
                storedSections[s].nodes.remove(at: node)
            }
            let step = inserting == nil ? -1 : 1
            // A removed node was a loose row, so a group at or after the place is after it both ways.
            for (group, path) in groupPaths where path.section == s && path.node >= node {
                groupPaths[group] = (s, path.node + step)
            }
            sectionsRevision &+= 1
            structureRevision = sectionsRevision
        }
        rowIndex = nil // as the setter: the next reader of a row's place builds it again
    }

    /// Whether `sections` list workspace `id` once (a scan that stops at a second listing; no index is built).
    static func listsOnce(_ id: WorkspaceID, in sections: [SidebarSection]) -> Bool {
        var seen = 0
        for section in sections {
            for node in section.nodes {
                switch node {
                case let .workspace(ws): if ws.id == id { seen += 1 }
                case let .group(group): seen += group.workspaces.lazy.filter { $0.id == id }.count
                case .item: break
                }
                if seen > 1 { return false }
            }
        }
        return seen == 1
    }
}
