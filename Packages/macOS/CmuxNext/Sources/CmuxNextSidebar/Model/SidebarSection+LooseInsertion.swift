/// A set of the sections that only adds one loose workspace row (SIDEBAR INSERT 2: Cmd-N's stand-in row at the press,
/// a scripted create): the list splices that one row into the layout it shows (`SidebarLayout.insertLoose`) instead
/// of laying every row out again.
public nonisolated struct SidebarRowInsertion: Sendable {
    /// `SidebarModel.sectionsRevision` before the set and after it: the list splices only onto the layout it built at
    /// `from`, and only for the set that made `to`.
    let from: UInt64
    let to: UInt64
    /// `SidebarModel.contentRevision` after the set: a row patch since (in place, no structural set) changed the rows
    /// `section` holds, so the list lays out in full.
    let content: UInt64
    /// The section that lists the row, as the set left it.
    let section: SidebarSection
    /// The row's node index in `section`.
    let node: Int
    /// The model made this from a one-row change it took as its input (`SidebarModel.apply(_:)`): `section` is the
    /// section the model listed at `from` with the row put in (in a removal: taken out), and the workspace is listed
    /// once. The list does not compare the section's rows again. Never set by a full set, which found the row itself.
    var fromRowChange = false
    /// The inserted workspace.
    var workspace: SidebarWorkspace? {
        if case let .workspace(ws) = section.nodes[node] { ws } else { nil }
    }
}

nonisolated extension SidebarSection {
    /// Where `new` adds one loose workspace node to `old` with nothing else changed: the same sections in the same
    /// order, every other section equal, and in the one that changed the same shell and the same nodes but the one.
    /// Nil for any other change. One compare per node, no layout.
    static func looseInsertion(from old: [SidebarSection], to new: [SidebarSection]) -> (section: Int, node: Int)? {
        guard old.count == new.count else { return nil }
        var found: (section: Int, node: Int)?
        for s in old.indices where old[s] != new[s] {
            guard found == nil, new[s].nodes.count == old[s].nodes.count + 1 else { return nil }
            var (oldShell, newShell) = (old[s], new[s])
            (oldShell.nodes, newShell.nodes) = ([], [])
            guard oldShell == newShell else { return nil }
            let (before, after) = (old[s].nodes, new[s].nodes)
            // The first node that differs is the new one; every node after it is the old one before it.
            let k = before.indices.first { before[$0] != after[$0] } ?? before.count
            guard case .workspace = after[k], after[(k + 1)...].elementsEqual(before[k...]) else { return nil }
            found = (s, k)
        }
        return found
    }
}

/// A set of the sections that only takes one loose workspace row out (a close), or only moves one (a notification's
/// move to the top, a keyboard move, a scripted move): the list takes that row out of the layout it shows, and for a
/// move splices it back in at its new place (`SidebarLayout.removeLoose`, then `insertLoose`), instead of laying every
/// row out again (Leo 2026-11-04: interaction cost stays constant as workspaces grow).
public nonisolated struct SidebarRowRemoval: Sendable {
    /// `SidebarModel.sectionsRevision` before the set and after it (as `SidebarRowInsertion`).
    let from: UInt64
    let to: UInt64
    /// `SidebarModel.contentRevision` after the set.
    let content: UInt64
    /// The section that listed the row, as the removal leaves it (without the row).
    let section: SidebarSection
    /// The row's node index in `section` before the removal.
    let node: Int
    /// The workspace whose row goes.
    let workspace: SidebarWorkspace
    /// A move: the same workspace's row added back, onto the sections the removal leaves (its section as the set left it).
    let insertion: SidebarRowInsertion?
    /// As `SidebarRowInsertion.fromRowChange`.
    var fromRowChange = false
}

nonisolated extension SidebarSection {
    /// Where `new` takes one loose workspace node out of `old` with nothing else changed (`looseInsertion` the other
    /// way): its section and node index in `old`. Nil for any other change. One compare per node, no layout.
    static func looseRemoval(from old: [SidebarSection], to new: [SidebarSection]) -> (section: Int, node: Int)? {
        looseInsertion(from: new, to: old)
    }

    /// Where `new` moves one loose workspace node of `old` (in its section or to another), with nothing else changed:
    /// the sections with the node taken out (`middle`), the removal in `old`, and the insertion `middle` to `new`.
    /// Nil for any other change. A few compares per node, no layout.
    static func looseMove(from old: [SidebarSection], to new: [SidebarSection])
        -> (middle: [SidebarSection], removal: (section: Int, node: Int), insertion: (section: Int, node: Int))? {
        guard old.count == new.count else { return nil }
        let changed = old.indices.filter { old[$0] != new[$0] }
        guard changed.count == 1 || changed.count == 2 else { return nil }
        for s in changed where old[s].nodes.count >= new[s].nodes.count {
            let (before, after) = (old[s].nodes, new[s].nodes)
            // The moved node is where the nodes first differ (it moved down) or last differ (it moved up).
            let first = before.indices.first { $0 >= after.count || before[$0] != after[$0] }
            var (i, j) = (before.count - 1, after.count - 1)
            while i >= 0, j >= 0, before[i] == after[j] { (i, j) = (i - 1, j - 1) }
            var candidates: [Int] = []
            for k in [first, i >= 0 ? i : nil].compactMap({ $0 }) where !candidates.contains(k) { candidates.append(k) }
            for k in candidates {
                guard case let .workspace(moved) = before[k] else { continue }
                var middle = old
                middle[s].nodes.remove(at: k)
                guard let added = looseInsertion(from: middle, to: new),
                      case let .workspace(back) = new[added.section].nodes[added.node], back.id == moved.id else { continue }
                return (middle, (s, k), added)
            }
        }
        return nil
    }
}
