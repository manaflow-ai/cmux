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

    /// Publishes a tab list change once the visible state is complete, the unread sum of the
    /// workspaces that joined or left (UnreadLedger), and resumes the keyed waiters whose keys the
    /// apply changed (StoreWaiters).
    func publishTabListChange() {
        index.unread.flush()
        let cause = causes.takeTabList()
        if index.takeTabListChange() { causes.with(cause) { tabListRevision &+= 1 } }
        // The tab keys this publish added or dropped, net of the re-keys in between (StoreTabKeys).
        index.tabKeys.publish()
        waiters.settleTouched(in: self)
    }

    /// Runs `onWorkspaceListChanged` when the workspace set differs from
    /// the last one reported (outside a batch, once loaded). Order is not
    /// membership: a move or a group change leaves the set as it was. O(1): the
    /// index keeps the set's digest as workspaces join and leave it.
    func workspaceListMayHaveChanged() {
        // Tracked without a hook too: a hook installed later runs for the next change, not for
        // a set its installer (`reconcileMembership`) has just read.
        guard applyDepth == 0, isLoaded else { return }
        let cause = causes.takeWorkspaceSet()
        let list = index.workspaceListDigest
        guard list != notifiedWorkspaceList else { return }
        notifiedWorkspaceList = list
        causes.with(cause) {
            workspaceSetRevision &+= 1
            drainCost.listChanges &+= 1
            onWorkspaceListChanged?()
        }
    }
}
