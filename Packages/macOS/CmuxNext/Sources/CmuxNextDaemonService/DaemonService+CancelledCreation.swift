public import CmuxNextDaemon

/// A person's close of a tab or pane this client is still creating ("Close before create",
/// .cmux-scratch/motion-redesign/DESIGN.md 2026-10-18). The store takes it out of the visible
/// state at once and hides the daemon's object when it comes (``DaemonStore/cancelCreation(tab:)``);
/// this closes that object as soon as its surface is known, in one `close-tabs` commit that ends
/// its terminal and stays out of the closed history (`session_end`): the tab never existed for
/// the person, so Reopen Closed Tab never offers it.
extension DaemonService {
    /// Cancels the creation that shows provisional tab `id`; false for any other tab.
    public func cancelCreation(tab id: String) -> Bool {
        armCancelledCloses()
        return store.cancelCreation(tab: id)
    }

    /// Cancels the split that shows provisional pane `handle`; false for any other pane.
    public func cancelCreation(pane handle: PaneID) -> Bool {
        armCancelledCloses()
        return store.cancelCreation(pane: handle)
    }

    private func armCancelledCloses() {
        guard store.onCloseCancelledCreation == nil else { return }
        store.onCloseCancelledCreation = { [weak self] transaction, surface in self?.closeCancelledCreation(transaction, surface) }
    }

    private func closeCancelledCreation(_ transaction: ClientTransactionID, _ surface: SurfaceID) {
        let batch = supports(DaemonCapabilities.shared.batchClose)
        let reason: CloseReason? = supports(DaemonCapabilities.shared.closeReason) ? .sessionEnd : nil
        let store = store
        // task-owner: one close of a cancelled creation's daemon tab; its failure shows what the daemon kept
        Task { [weak self] in
            guard let self else { return }
            let closed: Void? = await request("close-tabs (cancelled creation)") { connection in
                if batch { _ = try await connection.closeTabs([surface], endTerminals: true, reason: reason) } else { try await connection.closeTab(surface) }
            }
            // The daemon kept it (or the link dropped): the records show what it has.
            if closed == nil { store.rejectIntent(transaction) }
        }
    }
}
