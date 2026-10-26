import CmuxNextWakeups

/// What the store derives once the visible state is complete, each published with the cause of the
/// changes that asked for it (``StoreCauses``), not the cause of whatever else its batch applied.
extension DaemonStore {
    /// A change moved a workspace, or changed its group or the set: one sidebar flattening once the
    /// visible state is complete, with the cause of those changes.
    func recomputeSidebarIfNeeded() {
        guard let cause = causes.sidebar else { return }
        sidebarNeedsRecompute = false
        causes.with(cause) { recomputeSidebar() }
    }

    /// Runs `body` as changes made by `cause` (``StoreCauses/with(_:_:)``): a tab list change it
    /// leaves for a later publish publishes with that cause, whatever else the publish carries.
    @discardableResult
    func withCause<T>(_ cause: ObservationCause, _ body: () -> T) -> T {
        let before = index.pendingTabListMark
        defer { if let after = index.pendingTabListMark, after != before { causes.noteTabList(cause) } }
        return causes.with(cause, body)
    }

    /// Publishes a tab list change once the visible state is complete, and resumes the keyed
    /// waiters whose keys the apply changed (StoreWaiters).
    func publishTabListChange() {
        let cause = causes.takeTabList()
        if index.takeTabListChange() { causes.with(cause) { tabListRevision &+= 1 } }
        waiters.settleTouched(in: self)
    }

    /// Runs `onWorkspaceListChanged` when the workspace set differs from
    /// the last one reported (outside a batch, once loaded). Order is not
    /// membership: a move or a group change leaves the set as it was.
    func workspaceListMayHaveChanged() {
        // Tracked without a hook too: a hook installed later runs for the next change, not for
        // a set its installer (`reconcileMembership`) has just read.
        guard applyDepth == 0, isLoaded else { return }
        guard checkedListGeneration != listGeneration else { return }
        checkedListGeneration = listGeneration
        let cause = causes.takeWorkspaceSet()
        if let notified = notifiedWorkspaceList, notified.count == workspaces.count,
           workspaces.allSatisfy({ notified.contains($0.listID) }) { return }
        let list = Set(workspaces.map(\.listID))
        guard list != notifiedWorkspaceList else { return }
        notifiedWorkspaceList = list
        causes.with(cause) {
            workspaceSetRevision &+= 1
            onWorkspaceListChanged?()
        }
    }

    func recomputeSidebar() {
        listGeneration &+= 1
        causes.noteFlattening()
        let ungrouped = workspaces.filter { workspace in workspace.group.map { id in !groups.contains { $0.id == id } } ?? true }
        var sections = [SidebarSection(group: nil, workspaces: ungrouped)]
        for group in groups.sorted(by: { $0.index < $1.index }) {
            sections.append(SidebarSection(group: group, workspaces: workspaces.filter { $0.group == group.id }))
        }
        let unchanged = sections.count == sidebarSections.count && zip(sections, sidebarSections).allSatisfy { new, old in
            new.group === old.group && new.workspaces.count == old.workspaces.count
                && zip(new.workspaces, old.workspaces).allSatisfy { $0 === $1 }
        }
        if !unchanged { sidebarSections = sections }
    }
}
