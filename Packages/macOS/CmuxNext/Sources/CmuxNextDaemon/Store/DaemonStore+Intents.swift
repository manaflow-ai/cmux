import Foundation

/// The confirmed mirror plus one ordered intent log (plans/cmux-next/
/// OWNERSHIP-PRINCIPLES.md, "Clients are projections"; ownership.md step 4).
///
/// The records show the visible state: the confirmed mirror with every
/// pending intent applied in order. Daemon events and snapshots never
/// apply to the visible state: `withOverlayLifted` first undoes the
/// overlay exactly (each apply recorded its inverse, and nothing else
/// writes the records in between; debug builds check that), applies them
/// to the confirmed records, drops the intents that are now settled and
/// applies the rest again in order.
///
/// An intent leaves the log exactly once: on the daemon's echo of its
/// transaction, once the store applied every event up to its settle
/// sequence (the event sequence read after the command's reply, a
/// read-your-writes barrier; `mutation-echo-v1`'s `request-settled` will
/// supply the same sequence through `noteSettled`), or on rejection.
extension DaemonStore {
    /// Adds `intent` to the log and shows it. The caller sends the command
    /// carrying `transaction`, then calls `noteSettled` after the reply or
    /// `rejectIntent` when it failed.
    public func intend(_ intent: Intent, transaction: ClientTransactionID) {
        if overlayLifted {
            // Applied with the rest when the lift ends.
            _ = intentLog.append(intent, transaction: transaction)
            return
        }
        verifyMirrorUnchanged(before: "intent")
        guard intentLog.append(intent, transaction: transaction) else { return }
        intentLog.setUndo(IntentOverlay.apply(intent, to: self), at: intentLog.entries.count - 1)
        recomputeSidebarIfNeeded()
        recordMirror()
        workspaceListMayHaveChanged()
    }

    /// The overlay moved a workspace or changed its group: one sidebar
    /// flattening once the visible state is complete.
    private func recomputeSidebarIfNeeded() {
        guard sidebarNeedsRecompute else { return }
        sidebarNeedsRecompute = false
        recomputeSidebar()
    }

    /// The command for `transaction` replied: its effects are bounded by
    /// daemon event `sequence` (`DaemonConnection.eventSequence()` read
    /// after the reply). The intent settles once the store applied every
    /// event up to it, at once if it already has.
    public func noteSettled(_ transaction: ClientTransactionID, at sequence: UInt64) {
        intentLog.settle(transaction, at: sequence)
        settleDueIntents()
    }

    /// The command for `transaction` replied on a connection that is gone
    /// (no sequence to wait for): the intent settles with the next snapshot
    /// applied, which a later connection requests after the reply.
    public func noteSettledAtNextSnapshot(_ transaction: ClientTransactionID) {
        intentLog.settleAtSnapshot(transaction)
    }

    /// The command for `transaction` failed: the intent leaves the log and
    /// the visible state returns to the confirmed mirror (plus the others).
    public func rejectIntent(_ transaction: ClientTransactionID) {
        guard intentLog.contains(transaction) else { return }
        withOverlayLifted(writer: "intent rejection") { settleIntent(transaction, .rejected) }
    }

    /// The pending intents in order.
    public var pendingIntents: [Intent] { intentLog.entries.map(\.kind) }
    public var hasPendingIntents: Bool { !intentLog.isEmpty }

    /// The daemon echoed `transaction`. An echo carried by an event the
    /// store could not apply exactly (it resyncs) settles only once the
    /// snapshot covering `resyncSequence` is applied, so the tab never
    /// shows back at its old place in between.
    func settleIntentOnEcho(_ transaction: ClientTransactionID, needsResync: Bool, sequence: UInt64?) {
        guard intentLog.contains(transaction) else { return }
        if needsResync {
            if let sequence { intentLog.settle(transaction, at: sequence) }
            return
        }
        withOverlayLifted(writer: "intent echo") { settleIntent(transaction, .echoed) }
    }

    /// Drops the intents whose settle sequence the store reached (outside
    /// an apply; inside one, the lift's end does it).
    func settleDueIntents() {
        guard !overlayLifted, applyDepth == 0, intentLog.hasDue(appliedSequence: appliedSequence) else { return }
        withOverlayLifted(writer: "intent settlement") {}
    }

    /// Reported after the overlay is back (`withOverlayLifted`).
    private func settleIntent(_ transaction: ClientTransactionID, _ settlement: IntentSettlement) {
        guard intentLog.remove(transaction) != nil else { return }
        intentSettlements.append((transaction, settlement))
    }

    /// Runs `body` (event or snapshot apply, a settlement) on the confirmed
    /// records, then shows the pending intents again. `snapshot` settles the
    /// intents waiting for one. Nested calls run `body` directly.
    func withOverlayLifted<T>(writer: String = "daemon apply", snapshot: Bool = false, _ body: () -> T) -> T {
        guard !overlayLifted else { return body() }
        verifyMirrorUnchanged(before: writer)
        overlayLifted = true
        liftOverlay()
        let result = body()
        for intent in intentLog.removeDue(appliedSequence: appliedSequence, snapshot: snapshot) {
            intentSettlements.append((intent.transaction, .applied))
        }
        let confirmedTabs = debugTabCensus()
        restoreOverlay()
        overlayLifted = false
        recomputeSidebarIfNeeded()
        checkOverlayConservation(confirmed: confirmedTabs)
        recordMirror()
        workspaceListMayHaveChanged()
        // Observers see the visible state with the other intents on it.
        let settled = intentSettlements
        intentSettlements.removeAll()
        for (transaction, settlement) in settled { onIntentSettled?(transaction, settlement) }
        return result
    }

    /// A new connection replaces the last one (`run(connection:)`): its
    /// event sequences restart from its own serial, so the store's
    /// sequences reset, and intents whose reply came settle with its first
    /// snapshot.
    func beginConnection() {
        snapshotBarrier = 0
        if appliedSequence != 0 { appliedSequence = 0 }
        intentLog.connectionReplaced()
    }

    /// Undoes every overlay apply, newest first.
    private func liftOverlay() {
        for index in intentLog.entries.indices.reversed() {
            if let undo = intentLog.entries[index].undo { IntentOverlay.undo(undo, in: self) }
            intentLog.setUndo(nil, at: index)
        }
    }

    /// Applies every pending intent in order, recording each inverse.
    private func restoreOverlay() {
        for index in intentLog.entries.indices {
            intentLog.setUndo(IntentOverlay.apply(intentLog.entries[index].kind, to: self), at: index)
        }
    }
}
