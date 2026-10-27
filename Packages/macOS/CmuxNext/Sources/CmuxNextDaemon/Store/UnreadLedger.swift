/// The sum behind ``DaemonStore/unreadTotals``: what each indexed workspace adds
/// (``WorkspaceModel/unreadContribution``), kept by ``StoreIndex`` as workspaces join and leave it
/// and by a workspace when its own share changes. A change costs that workspace's share, never a
/// walk of the workspace list: a batch that moves, adds or retitles workspaces sums only those.
///
/// ```swift
/// ledger.onChange = { totals in store.publish(unread: totals) }
/// ledger.join(workspace)    // StoreIndex.insert(_:)
/// ledger.leave(workspace)   // StoreIndex.remove(_:)
/// ledger.flush()            // DaemonStore.publishTabListChange()
/// ```
@MainActor final class UnreadLedger {
    /// The indexed workspaces' shares, summed.
    private(set) var totals = UnreadTotals()
    /// Workspaces that joined since creation (tests: what a store change cost here).
    private(set) var joins = 0
    /// Called with ``totals`` after a share changed, and at ``flush()`` after joins and leaves.
    var onChange: (@MainActor (UnreadTotals) -> Void)?
    /// A join or leave changed ``totals`` since the last ``flush()``.
    private var unflushed = false

    /// `workspace` is indexed: its share counts from now on. Reported at the next ``flush()``: the
    /// index is mid-write here, and a re-index (a leave, then a join) changes nothing.
    func join(_ workspace: WorkspaceModel) {
        guard workspace.unreadLedger !== self else { return }
        workspace.unreadLedger?.leave(workspace)
        joins &+= 1
        workspace.unreadLedger = self
        let share = workspace.unreadContribution
        workspace.summedContribution = share
        totals.add(share)
        unflushed = true
    }

    /// `workspace` left the index: the share it last reported leaves the sum (at the next ``flush()``).
    func leave(_ workspace: WorkspaceModel) {
        guard workspace.unreadLedger === self else { return }
        workspace.unreadLedger = nil
        totals.subtract(workspace.summedContribution)
        unflushed = true
    }

    /// A joined workspace's share went from `old` to `new` (a model change, never mid index write).
    func change(from old: UnreadTotals, to new: UnreadTotals) {
        totals.subtract(old)
        totals.add(new)
        unflushed = false
        onChange?(totals)
    }

    /// Reports the joins and leaves since the last call (the store, once an apply's index writes end).
    func flush() {
        guard unflushed else { return }
        unflushed = false
        onChange?(totals)
    }
}
