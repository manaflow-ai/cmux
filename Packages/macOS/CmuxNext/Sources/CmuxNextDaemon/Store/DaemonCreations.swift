import Foundation

/// The store's pending creations as a close sees them (``CancelledCreation``): a close of a
/// provisional tab or pane cancels its creation, the creator asks whether it was cancelled, and
/// a split's reply names the daemon's surface for that close.
@MainActor public struct DaemonCreations {
    let store: DaemonStore

    /// A close of tab `id` while it is a pending creation's provisional tab: it leaves the visible
    /// state now and the daemon's tab never shows. False for any other tab (it closes as usual).
    public func cancel(tab id: String) -> Bool {
        guard let transaction = CancelledCreation.transaction(showingTab: id, in: store) else { return false }
        CancelledCreation.cancel(transaction, in: store)
        return true
    }

    /// The same for the provisional pane `handle` of a pending split.
    public func cancel(pane handle: PaneID) -> Bool {
        guard let transaction = CancelledCreation.transaction(showingPane: handle, in: store) else { return false }
        CancelledCreation.cancel(transaction, in: store)
        return true
    }

    /// Whether a close of the daemon's surface of a cancelled creation is wired (`onClose`).
    public var closes: Bool { store.intentLog.closeCancelled != nil }

    /// `close` gets each cancelled creation's daemon surface once it is known (the service sends
    /// `close-tabs`; a failure rejects the intent, so the records show what the daemon kept).
    public func onClose(_ close: @escaping (ClientTransactionID, SurfaceID) -> Void) { store.intentLog.closeCancelled = close }

    /// Whether tab `id` is still a pending creation's provisional tab (a close cancels it).
    public func isPending(tab id: String) -> Bool { CancelledCreation.transaction(showingTab: id, in: store) != nil }

    /// Whether the person closed what `transaction` creates: its creator then selects, focuses
    /// and reports nothing of it. Known for a while after its intent left the log.
    public func wasCancelled(_ transaction: ClientTransactionID) -> Bool { store.intentLog.wasCancelled(transaction) }

    /// The creation's reply named the daemon's `surface` (a split's; a create's goes through
    /// ``ProvisionalTab/created(_:surface:in:)``): a cancelled one can close it now.
    public func noteReply(_ transaction: ClientTransactionID, surface: SurfaceID) {
        store.intentLog.noteReplySurface(transaction, surface: surface)
        CancelledCreation.requestCloses(in: store)
    }
}

extension DaemonStore { public var creations: DaemonCreations { DaemonCreations(store: self) } }

extension CancelledCreation {
    /// Marks `transaction`'s creation cancelled (once): the lift undoes its provisional tab or
    /// pane, and the restore shows the cancelled overlay (nothing, or the daemon's object hidden).
    static func cancel(_ transaction: ClientTransactionID, in store: DaemonStore) {
        guard !store.intentLog.wasCancelled(transaction), store.intentLog.markCloseWhenCreated(transaction) else { return }
        store.withOverlayLifted(writer: "creation cancelled") {}
        requestCloses(in: store)
    }

    /// Hands each cancelled creation's daemon surface to the close once, as soon as it is known.
    static func requestCloses(in store: DaemonStore) {
        guard !store.overlayLifted else { return }
        for entry in store.intentLog.entries where entry.closeWhenCreated && !entry.closeRequested {
            guard let surface = closeSurface(entry) else { continue }
            store.intentLog.noteCloseRequested(entry.transaction)
            store.intentLog.closeCancelled?(entry.transaction, surface)
        }
    }
}
