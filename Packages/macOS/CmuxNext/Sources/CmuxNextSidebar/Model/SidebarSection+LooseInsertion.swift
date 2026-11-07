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
