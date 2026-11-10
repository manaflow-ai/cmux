/// SIDEBAR ROW CHANGE stage 2: one loose workspace row gone from a window's list or new in it, as the INPUT of the
/// model and the list (Chromium's `TabStripModelChange`: the strip gets the change with its index and lays out from
/// it; it never finds the change by a compare of the old tabs and the new ones). `SidebarModel.setSections` took the
/// whole new list and found the one row by reading every listed row several times (826 workspaces: 1688 rows read per
/// close after stage 1).
///
/// `section` and `node` name the row's place in the rows the caller gave to the last `SidebarModel.setSections`; the
/// model takes a change only while its own rows have the same places (no document arrangement, no hidden node).
public nonisolated enum SidebarLooseRowChange: Sendable, Equatable {
    /// The loose row of workspace `id`, node `node` of `section`, left the list. Every other row stays.
    case removed(WorkspaceID, section: SectionID, node: Int)
    /// `workspace`'s loose row is new at node `node` of `section`. Every other row stays.
    case added(SidebarWorkspace, section: SectionID, node: Int)
}

/// What the last full set (`SidebarModel.setSections`) knows for `SidebarModel.apply(_:)`: whether the model's rows
/// sit at the caller's places, and how many times they list each workspace. The full set counts the listings (one
/// more read of each row in a set that reads each row several times); each one-row change keeps the count in step.
nonisolated struct SidebarRowChangeBase: Sendable {
    /// The hidden items of the last full set: a change of them hides other nodes.
    private(set) var hidden: Set<LayoutItemRef> = []
    /// The model's rows are the caller's with nothing moved, added or left out: no document arrangement, the same
    /// sections, and each with as many nodes (a hidden item takes a node out).
    private(set) var samePlaces = false
    /// How many times the rows list each workspace (loose or in a group). Nil: not counted, no change is taken.
    private(set) var listings: [WorkspaceID: Int]?
    /// The workspaces listed more than once: the list draws one row for each, so its rows are not the model's.
    private(set) var repeated = 0
    /// The model's `structureRevision` that `listings` counts: another structural write leaves them behind.
    private(set) var structure: UInt64 = 0

    /// A full set of `given`, which the model shows as `shown`.
    mutating func note(given: [SidebarSection], shown: [SidebarSection], hidden: Set<LayoutItemRef>, arranged: Bool) {
        self.hidden = hidden
        samePlaces = !arranged && given.count == shown.count
            && zip(given, shown).allSatisfy { $0.id == $1.id && $0.nodes.count == $1.nodes.count }
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
        listings = counts
        self.repeated = repeated
        self.structure = structure
    }

    /// A one-row change the model took: `id` is listed once now (`listed`) or not at all, at `structure`.
    mutating func took(_ id: WorkspaceID, listed: Bool, structure: UInt64) {
        listings?[id] = listed ? 1 : nil
        self.structure = structure
    }
}

extension SidebarModel {
    /// Whether the model takes a one-row change now: its rows are the caller's at the same places (the last full set
    /// had no document arrangement and hid no node, and nothing wrote the structure since), no workspace is listed
    /// twice, and no filter, hidden-item change or document decides which rows show. O(sections).
    public var takesRowChanges: Bool {
        // Read in place: a copy of the base held over a change would make its count copy itself (every workspace).
        guard rowChangeBase.samePlaces, rowChangeBase.listings != nil, rowChangeBase.repeated == 0,
              rowChangeBase.structure == structureRevision, filterText.isEmpty, splicesRemovals,
              hiddenItemRefs == rowChangeBase.hidden, docDrag?.document?.shown == nil else { return false }
        // A full set folds each section as the window has it: a section that it would fold or open is more than one row.
        return !storedSections.contains { $0.isCollapsed != collapsedSections.contains($0.id) }
    }

    /// Shows `change` as `setSections` shows the same rows without the row, or with it: the one node goes out of its
    /// section or comes in, the revisions move as a structural set moves them, and the list gets the row as
    /// `rowRemoval` or `rowInsertion`. No other row is read. False, with nothing changed, when the model can not prove
    /// that (`takesRowChanges`, a row that is not a loose row at that place, a workspace listed elsewhere): the caller
    /// then sets the sections.
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
            guard let s = uniqueSection(section), storedSections[s].nodes.indices.contains(node),
                  case let .workspace(ws) = storedSections[s].nodes[node], ws.id == id, rowChangeBase.listings?[id] == 1 else { return false }
            writeRowChange(section: s, node: node, inserting: nil)
            rowChangeBase.took(id, listed: false, structure: structureRevision)
            rowInsertion = nil
            rowRemoval = SidebarRowRemoval(from: from, to: sectionsRevision, content: contentRevision, section: storedSections[s], node: node,
                                           workspace: ws, insertion: nil, fromRowChange: true)
        case let .added(ws, section, node):
            guard let s = uniqueSection(section), node >= 0, node <= storedSections[s].nodes.count,
                  rowChangeBase.listings?[ws.id] == nil else { return false }
            writeRowChange(section: s, node: node, inserting: ws)
            rowChangeBase.took(ws.id, listed: true, structure: structureRevision)
            rowInsertion = SidebarRowInsertion(from: from, to: sectionsRevision, content: contentRevision, section: storedSections[s], node: node,
                                               fromRowChange: true)
            rowRemoval = nil
        }
        SidebarPerfCounters.add(.rowChanges)
        SidebarPerfCounters.add(.rowsWalked) // the changed row
        return true
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
