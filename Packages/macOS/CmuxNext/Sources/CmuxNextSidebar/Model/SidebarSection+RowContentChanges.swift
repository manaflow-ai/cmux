/// One listed workspace row whose content a set of the sections changed, at its place.
nonisolated struct SidebarRowContentChange {
    let path: SidebarRowIndex.Path
    let old: SidebarWorkspace
    let new: SidebarWorkspace
}

nonisolated extension SidebarSection {
    /// The workspace rows whose content differs from `old` to `new` when nothing else does: the same sections, groups
    /// and items, every listed workspace in its place with the same id, machine, archive state and row state (or its
    /// create's stand-in, `.creating`, now the live row). Empty when the two are equal; nil for a structural change
    /// (a row added, removed or moved, a section's or a group's own fields), which lays the list out again.
    ///
    /// One compare per row, no layout: a create's stand-in becoming its workspace's row (SIDEBAR INSERT) is one row's
    /// change, so it costs one row's patch (`SidebarModel.patchWorkspaces`'s path), at 50 rows as at 10,000.
    static func rowContentChanges(from old: [SidebarSection], to new: [SidebarSection]) -> [SidebarRowContentChange]? {
        guard old.count == new.count else { return nil }
        var changes: [SidebarRowContentChange] = []
        for s in old.indices where old[s] != new[s] {
            var (oldShell, newShell) = (old[s], new[s])
            (oldShell.nodes, newShell.nodes) = ([], [])
            guard oldShell == newShell, old[s].nodes.count == new[s].nodes.count else { return nil }
            for n in old[s].nodes.indices {
                switch (old[s].nodes[n], new[s].nodes[n]) {
                case let (.workspace(before), .workspace(after)):
                    guard before != after else { continue }
                    guard keepsPlace(before, after) else { return nil }
                    changes.append(SidebarRowContentChange(path: .init(section: s, node: n, member: nil), old: before, new: after))
                case let (.group(before), .group(after)):
                    guard before != after else { continue }
                    var (oldGroup, newGroup) = (before, after)
                    (oldGroup.workspaces, newGroup.workspaces) = ([], [])
                    guard oldGroup == newGroup, before.workspaces.count == after.workspaces.count else { return nil }
                    for m in before.workspaces.indices where before.workspaces[m] != after.workspaces[m] {
                        guard keepsPlace(before.workspaces[m], after.workspaces[m]) else { return nil }
                        changes.append(SidebarRowContentChange(path: .init(section: s, node: n, member: m),
                                                               old: before.workspaces[m], new: after.workspaces[m]))
                    }
                case let (.item(before), .item(after)):
                    guard before == after else { return nil }
                default:
                    return nil
                }
            }
        }
        return changes
    }

    /// Whether `after` is `before`'s row in the same place: the same workspace on the same machine, archived alike,
    /// in the same row state or its create's stand-in turned live (a placeholder or a saved row turning live
    /// swaps every row at once and lays the list out, as before).
    private static func keepsPlace(_ before: SidebarWorkspace, _ after: SidebarWorkspace) -> Bool {
        before.id == after.id && before.machineID == after.machineID && before.isArchived == after.isArchived
            && (before.rowState == after.rowState || before.rowState == .creating && after.rowState == .live)
    }
}
