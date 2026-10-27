/// The sidebar's sections (``DaemonStore/sidebarSections``): the workspaces in daemon order, the
/// ungrouped ones first, then one section per group in the groups' order.
extension DaemonStore {
    /// Flattens the sidebar in one pass over the workspaces and one over the groups: O(workspaces),
    /// once per apply that changed the order, the membership or a group (`sidebarNeedsRecompute`).
    /// An apply that changes only records inside workspaces, and the lift and restore of an
    /// unchanged overlay, run none. Sections are assigned only when one differs, so their observers
    /// wake only for a new list. Patching only the sections a batch touches is p06-scheduler-033b.
    func recomputeSidebar() {
        drainCost.sidebarFlattens &+= 1
        causes.noteFlattening()
        var members: [WorkspaceGroupID: [WorkspaceModel]] = [:]
        members.reserveCapacity(groups.count)
        for group in groups { members[group.id] = [] }
        var ungrouped: [WorkspaceModel] = []
        for workspace in workspaces {
            if let id = workspace.group, members[id] != nil {
                members[id, default: []].append(workspace)
            } else {
                ungrouped.append(workspace)
            }
        }
        var sections = [SidebarSection(group: nil, workspaces: ungrouped)]
        for group in groups.sorted(by: { $0.index < $1.index }) {
            sections.append(SidebarSection(group: group, workspaces: members[group.id] ?? []))
        }
        let unchanged = sections.count == sidebarSections.count && zip(sections, sidebarSections).allSatisfy { new, old in
            new.group === old.group && new.workspaces.count == old.workspaces.count
                && zip(new.workspaces, old.workspaces).allSatisfy { $0 === $1 }
        }
        if !unchanged { sidebarSections = sections }
    }
}
