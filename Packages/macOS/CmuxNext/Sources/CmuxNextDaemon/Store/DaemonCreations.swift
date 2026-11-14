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
        if CancelledCreation.keepsCreation(transaction, in: store) {
            CancelledCreation.closeStandIn(transaction, in: store)
        } else {
            CancelledCreation.cancel(transaction, in: store)
        }
        return true
    }

    /// A close of a pane while the focus names tab `id`: cancels only a pending split showing it
    /// (a Close Pane right after Cmd-T keeps the pane). False otherwise.
    public func cancel(splitShowing id: String) -> Bool {
        guard let transaction = CancelledCreation.transaction(showingTab: id, in: store),
              store.intentLog.entries.contains(where: { if case .splitPane = $0.kind { $0.transaction == transaction } else { false } }) else { return false }
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

    /// The close of `transaction`'s daemon surface timed out (it may or may not have committed):
    /// once the records say (call after a refresh), a creation whose tab is still there sends
    /// its close again, at most ``closeAttemptLimit`` times; one whose tab is gone has left.
    public func closeTimedOut(_ transaction: ClientTransactionID) {
        guard store.intentLog.allowCloseRetry(transaction, limit: Self.closeAttemptLimit) else { return }
        CancelledCreation.requestCloses(in: store)
    }

    /// Sends of a cancelled creation's close before its tab is left to the records (shown again
    /// only if a snapshot says the daemon kept it).
    public static let closeAttemptLimit = 3

    /// The tab of `pane` that stand-in tab `id` became, once the records list it there in its place
    /// (a confirmed reply or echo named it). A pane's strip shows the records one observation step
    /// late: a Cmd-W in that step still names the stand-in, which the records no longer hold, and
    /// closed nothing (smoke, STATUS 4852). Nil for any other id, and for a stand-in still shown,
    /// cancelled (its tab is hidden) or refused.
    public func replacement(ofStandIn id: String, in pane: PaneModel) -> TabModel? {
        guard ProvisionalTab.isProvisional(id), let surface = store.intentLog.replacement(ofStandIn: id) else { return nil }
        return pane.tabs.first { $0.surface == surface }
    }

    /// Whether stand-in tab `id` stands for a creation still under way: neither closed by the person (cancelled) nor answered
    /// (a confirmed reply or echo named its tab). A new tab placed right after it keeps it as its anchor while it is out of the
    /// records (`NewTabSuccession`). Any creation's stand-in: a new tab's, a new workspace's first tab, a conversation split's
    /// tab, a dock's fresh tab (review F2 on #37799: only a new tab's counted, so a tab opened after the others was re-anchored).
    public func isUnderway(standIn id: String) -> Bool {
        store.intentLog.entries.contains { entry in
            !entry.closeWhenCreated && !entry.standInClosed && !entry.createdConfirmed && entry.kind.standInTab?.tabResourceID?.rawValue == id
        }
    }

    /// Whether `pane`'s tab `id` is the tab a creation made in its stand-in's place, named by the daemon (its reply, its echo
    /// or its terminal's host id) and not closed by the person: the one arrival a stand-in leaving in the same step can have
    /// become. A tab moved in, a script's, or one arriving as a closed stand-in leaves is none (review F3 on #37799).
    public func tookAStandInsPlace(tab id: String, in pane: PaneModel) -> Bool {
        guard let surface = pane.tabs.first(where: { $0.id == id })?.surface else { return false }
        return store.intentLog.replacedAStandIn(surface) && !store.intentLog.entries.contains { $0.createdSurface == surface && ($0.closeWhenCreated || $0.standInClosed) }
    }

    /// Whether `pane`'s tab `id` is what stand-in tab `standIn` became, so it may take the stand-in's cell and selection: the daemon
    /// named it as that stand-in's creation's (its reply, its echo or its terminal's host id), or it carries the terminal host id
    /// the stand-in's creation minted (a dock's fresh tab, which no reply names), pending or settled. Never a tab moved in, a
    /// script's, a closed stand-in's (F1 on #38085), or another stand-in's (F2 on #38108).
    public func became(standIn: String, tab id: String, in pane: PaneModel) -> Bool {
        guard let tab = pane.tabs.first(where: { $0.id == id }) else { return false }
        if store.intentLog.replacement(ofStandIn: standIn) == tab.surface {
            return !store.intentLog.entries.contains { $0.createdSurface == tab.surface && ($0.closeWhenCreated || $0.standInClosed) }
        }
        guard let terminal = tab.snapshot.terminalID else { return false }
        if store.intentLog.settled(standIn: standIn, minted: terminal) { return true }
        return store.intentLog.entries.contains { entry in
            !entry.closeWhenCreated && !entry.standInClosed && entry.kind.standInTab.map { $0.tabResourceID?.rawValue == standIn && $0.terminalID == terminal } == true
        }
    }

    /// Whether stand-in tab `standIn`, leaving as `pane`'s tab `id` arrives alone, hands that tab its cell and selection: yes for
    /// the tab it became (``became(standIn:tab:in:)``), and for a tab not yet named (a swap observed before its record lands, as
    /// before #38108); never when the person closed the stand-in (F1 on #38085) or the tab is another stand-in's (F2 on #38108).
    public func handsOver(standIn: String, to id: String, in pane: PaneModel) -> Bool {
        if became(standIn: standIn, tab: id, in: pane) { return true }
        let closed = store.intentLog.entries.contains { ($0.closeWhenCreated || $0.standInClosed) && $0.kind.standInTab?.tabResourceID?.rawValue == standIn }
        return !closed && !tookAStandInsPlace(tab: id, in: pane)
    }

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

extension DaemonStore {
    public var creations: DaemonCreations { DaemonCreations(store: self) }

    /// A close of pane `handle` while it is still opening (a stand-in no cancel took, e.g. a dock's pane): it leaves
    /// the visible records now, and the daemon's pane that takes it over stays out until the close commits. The
    /// caller sends `close-pane` for ``daemonTarget(_:)``, then settles (`noteSettled`) or rejects the transaction.
    /// Nil for a daemon pane (its close needs no intent).
    public func intendStandInPaneClose(_ handle: PaneID) -> ClientTransactionID? {
        guard handle.rawValue >= ProvisionalPane.firstHandle else { return nil }
        let origin = standInTargets[handle] ?? ProvisionalSplit.standInOrigin(of: handle, in: self)
        var paneID = panesByHandle[handle]?.resourceID?.rawValue, workspace: WorkspaceKey?
        switch origin {
        case .pane(let id)?: paneID = id
        case .workspace(let key)?: workspace = key
        case nil: break
        }
        let transaction = ClientTransactionID.generate()
        intend(.closeStandInPane(pane: handle, paneID: paneID, workspace: workspace), transaction: transaction)
        return transaction
    }
}

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
        for entry in store.intentLog.entries where (entry.closeWhenCreated || entry.standInClosed) && !entry.closeRequested {
            // A create's tab paired by a guess (``ProvisionalTab/matched(_:in:)``) is hidden but
            // closed only once the daemon names it for this transaction: a wrong guess never
            // closes another create's tab.
            if case .createTab = entry.kind, !entry.createdConfirmed, entry.replySurface == nil { continue }
            guard let surface = closeSurface(entry) else { continue }
            store.intentLog.noteCloseRequested(entry.transaction)
            store.intentLog.closeCancelled?(entry.transaction, surface)
        }
    }
}
