import Foundation

/// Closing a tab or pane before the daemon created it (``CancelledCreation``).
extension DaemonStore {
    /// A close of tab `id` while it is a pending creation's provisional tab: it leaves the visible
    /// state now and the daemon's tab never shows. False for any other tab (it closes as usual).
    /// A second call for the same creation is a no-op that returns true.
    public func cancelCreation(tab id: String) -> Bool {
        guard let transaction = CancelledCreation.transaction(showingTab: id, in: self) else { return false }
        cancelCreation(transaction)
        return true
    }

    /// The same for the provisional pane `handle` of a pending split.
    public func cancelCreation(pane handle: PaneID) -> Bool {
        guard let transaction = CancelledCreation.transaction(showingPane: handle, in: self) else { return false }
        cancelCreation(transaction)
        return true
    }

    /// Whether tab `id` is still a pending creation's provisional tab (a close cancels it).
    public func isCreating(tab id: String) -> Bool { CancelledCreation.transaction(showingTab: id, in: self) != nil }

    /// Whether the person closed what `transaction` creates (its creator then selects, focuses and
    /// reports nothing of it).
    public func creationCancelled(_ transaction: ClientTransactionID) -> Bool {
        intentLog.wasCancelled(transaction)
    }

    /// The creation's reply named the daemon's `surface` (a split's; a create's goes through
    /// ``ProvisionalTab/created(_:surface:in:)``): a cancelled one can close it now.
    public func noteCreationReply(_ transaction: ClientTransactionID, surface: SurfaceID) {
        intentLog.noteReplySurface(transaction, surface: surface)
        requestCancelledCloses()
    }

    private func cancelCreation(_ transaction: ClientTransactionID) {
        guard !creationCancelled(transaction), intentLog.markCloseWhenCreated(transaction) else { return }
        // The lift undoes the provisional tab or pane; the restore shows the cancelled overlay.
        withOverlayLifted(writer: "creation cancelled") {}
        requestCancelledCloses()
    }

    /// Hands each cancelled creation's daemon surface to the close once, as soon as it is known.
    func requestCancelledCloses() {
        guard !overlayLifted else { return }
        for entry in intentLog.entries where entry.closeWhenCreated && !entry.closeRequested {
            guard let surface = CancelledCreation.closeSurface(entry) else { continue }
            intentLog.noteCloseRequested(entry.transaction)
            onCloseCancelledCreation?(entry.transaction, surface)
        }
    }
}
