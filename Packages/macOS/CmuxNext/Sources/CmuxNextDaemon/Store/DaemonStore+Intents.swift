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
        // A script batch's intent waits for its stage to commit (DaemonStore+Stage.swift).
        if let stage, stage.holds(intent, transaction: transaction, in: self) {
            _ = intentLog.append(intent, transaction: transaction, held: true)
            return
        }
        if overlayLifted {
            // Applied with the rest when the lift ends.
            _ = intentLog.append(intent, transaction: transaction)
            return
        }
        verifyMirrorUnchanged(before: "intent")
        guard intentLog.append(intent, transaction: transaction) else { return }
        if !intentLog.setUndo(IntentOverlay.apply(intent, to: self), at: intentLog.entries.count - 1) { reportMirrorViolation("intent log is empty after an append") }
        recomputeSidebarIfNeeded()
        publishTabListChange()
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

    /// The daemon echoed `transaction`. An echo carried by an event the
    /// store could not apply exactly (it resyncs) settles only once the
    /// snapshot covering `resyncSequence` is applied, so the tab never
    /// shows back at its old place in between.
    func settleIntentOnEcho(_ transaction: ClientTransactionID, needsResync: Bool, sequence: UInt64?) {
        guard let entry = intentLog.entries.first(where: { $0.transaction == transaction }) else { return }
        // A split's `pane-added` echo comes before the `layout-changed` that places the pane:
        // it stays until the records place it (cx-ry0y), as when its reply settles it.
        if ProvisionalSplit.awaitsRecords(entry, in: self) { return intentLog.awaitRecords(transaction) }
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
        guard let removed = intentLog.remove(transaction) else { return }
        intentSettlements.append((transaction, settlement))
        noteIntentLeft(removed, rejected: settlement == .rejected)
        // A refused create held a guessed tab that was another create's: guess it again.
        if settlement == .rejected, !removed.createdConfirmed, let surface = removed.createdSurface {
            ProvisionalTab.reguess(surface, in: self)
        }
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
        let landed = MovedTabSplit.takeLanded(in: self)
        for intent in intentLog.removeDue(appliedSequence: appliedSequence, snapshot: snapshot, awaiting: { ProvisionalSplit.awaitsRecords($0, in: self) }) {
            intentSettlements.append((intent.transaction, .applied))
            noteIntentLeft(intent, rejected: false)
        }
        releaseSettledProvisionalPanes()
        releaseStandInTargets()
        releaseSettledProvisionalWorkspaces()
        let confirmedTabs = debugTabCensus()
        restoreOverlay()
        overlayLifted = false
        recomputeSidebarIfNeeded()
        publishTabListChange()
        checkOverlayConservation(confirmed: confirmedTabs)
        recordMirror()
        workspaceListMayHaveChanged()
        // Observers see the visible state with the other intents on it.
        let settled = intentSettlements
        intentSettlements.removeAll()
        for (transaction, settlement) in settled { onIntentSettled?(transaction, settlement) }
        CancelledCreation.requestCloses(in: self)
        // A create waiting for a stand-in's daemon pane goes on once this apply made or refused it.
        resolveStandInWaits()
        for (handOver, surface) in landed { handOver(surface) }
        return result
    }

    /// The pane model of a split that left the log (settled or refused) is no longer provisional.
    private func releaseSettledProvisionalPanes() {
        guard !provisionalPanes.isEmpty || !movedTabSplits.isEmpty else { return }
        let pending = Set(intentLog.entries.compactMap { entry -> String? in
            if !entry.closeWhenCreated, case .splitPane(_, _, _, let provisional) = entry.kind { return provisional.paneID }
            return nil
        })
        provisionalPanes = provisionalPanes.filter { pending.contains($0.key) }
        MovedTabSplit.prune(in: self)
    }

    /// A stand-in handle stays resolvable while a pending create names it as its target.
    private func releaseStandInTargets() {
        guard !standInTargets.isEmpty else { return }
        let targets = Set(intentLog.entries.compactMap { entry -> PaneID? in
            if case .splitPane(let target, _, _, _) = entry.kind { return target }
            if case .createTab(let target, _) = entry.kind { return target }
            return nil
        })
        standInTargets = standInTargets.filter { targets.contains($0.key) }
    }

    /// The record of a pane the daemon reports: the provisional pane's own model when a pending
    /// split shows it under the same public id, updated in place, so its observers keep their
    /// object and see only the fields that changed (perf I3); else a new model.
    /// The daemon pane a command about `handle` must name: `handle` itself for a daemon pane, the
    /// daemon's pane that took a pending create's stand-in over (same public id), or nil while the
    /// stand-in is not confirmed yet (a create pressed on a create still in flight waits for it).
    public func daemonHandle(showing handle: PaneID) -> PaneID? {
        ProvisionalSplit.daemonHandle(showing: handle, in: self)
    }

    /// The pane a create about `handle` sends (rule b: a stand-in id never leaves for the daemon): `handle` for a daemon
    /// pane; for a stand-in, the daemon's pane that took it over. One seam for every create (Cmd-D, New Column, New Row,
    /// New Terminal Tab): a stand-in whose own create is still in flight (Cmd-N's first pane, a split) is a valid
    /// target, and the create waits here, off the key's turn, until the daemon's pane takes it over (the store resumes
    /// it from the reconcile that applies it; no timer). A stand-in whose create failed or was closed was never made:
    /// ``PendingPaneNotCreated``, which the action shows as a refusal. P0 STATUS 2080: Ctrl-` right after Cmd-N was
    /// refused here ("still opening; try again"), and no terminal opened.
    public func daemonTarget(_ handle: PaneID) async throws -> PaneID {
        guard handle.rawValue >= ProvisionalPane.firstHandle else { return handle }
        let origin = standInTargets[handle] ?? ProvisionalSplit.standInOrigin(of: handle, in: self)
        switch StandInWait.state(of: handle, origin: origin, in: self) {
        case .adopted(let pane): return pane
        case .notCreated: throw PendingPaneNotCreated()
        case .opening: return try await waitForDaemonPane(of: handle, origin: origin)
        }
    }

    func confirmedPane(_ snapshot: PaneSnapshot) -> PaneModel {
        guard let model = provisionalPanes.removeValue(forKey: PaneModel.identity(snapshot)) else { return PaneModel(snapshot) }
        model.update(snapshot)
        return model
    }

    /// The record of a workspace the daemon reports: the provisional workspace's own model when a
    /// pending create shows it under the same key, updated in place (as ``confirmedPane(_:)``);
    /// else a new model.
    func confirmedWorkspace(_ snapshot: WorkspaceSnapshot) -> WorkspaceModel {
        guard let model = provisionalWorkspaces.workspacesByID[WorkspaceModel.identity(snapshot)] else { return WorkspaceModel(snapshot) }
        model.update(snapshot)
        return model
    }

    /// The models of a workspace create that left the log (settled or refused) are no longer provisional.
    private func releaseSettledProvisionalWorkspaces() {
        guard !provisionalWorkspaces.workspacesByID.isEmpty || !provisionalWorkspaces.screensByID.isEmpty else { return }
        let pending = Set(intentLog.entries.compactMap { entry -> String? in
            if case .createWorkspace(let provisional, _) = entry.kind { return provisional.key.rawValue }
            return nil
        })
        provisionalWorkspaces.workspacesByID = provisionalWorkspaces.workspacesByID.filter { pending.contains($0.key) }
        provisionalWorkspaces.screensByID = provisionalWorkspaces.screensByID.filter { pending.contains($0.key) }
    }

    /// A new connection replaces the last one (`run(connection:)`): its
    /// event sequences restart from its own serial, so the store's
    /// sequences reset, and intents whose reply came settle with its first
    /// snapshot.
    func beginConnection() {
        // A stage of the old connection holds its events and sequences: the new one's snapshot is the truth.
        stage?.discard()
        sequenceWaits = [:]
        snapshotBarrier = 0
        if appliedSequence != 0 { appliedSequence = 0 }
        intentLog.connectionReplaced()
    }

    /// Undoes every overlay apply, newest first.
    private func liftOverlay() {
        for index in intentLog.entries.indices.reversed() {
            if let undo = intentLog.entries[checked: index]?.undo { IntentOverlay.undo(undo, in: self) }
            if !intentLog.setUndo(nil, at: index) { reportMirrorViolation("intent log has no entry \(index)") }
        }
    }

    /// Applies every pending intent in order, recording each inverse.
    private func restoreOverlay() {
        for (index, entry) in intentLog.entries.enumerated() where !entry.held { // IntentOverlay never writes the log
            if !intentLog.setUndo(IntentOverlay.restore(entry, to: self), at: index) { reportMirrorViolation("intent log has no entry \(index)") }
        }
    }
}

/// A command named a stand-in pane whose create never made the daemon's pane (it was refused or closed first).
public struct PendingPaneNotCreated: Error, CustomStringConvertible {
    public init() {}
    /// Plain English, as every ``DaemonError`` text of this module (it has no string catalog).
    public var description: String { "the pane it was for was not created" }
}

/// A pane verb (zoom, rename, swap, a page in it) named a pane that is still opening (a pending create's stand-in): it was
/// not sent, since the daemon does not know that pane yet. The app shows it as a refusal (`DaemonService.onPaneNotReady`).
public struct PaneNotReady: Error, CustomStringConvertible {
    public let command: String
    public let reference: String
    /// The person saw this refusal already (the connection showed it: `DaemonConnection.observePaneNotReady`), so no
    /// caller shows it again.
    public var shown = false
    public init(command: String, reference: String) {
        self.command = command
        self.reference = reference
    }
    /// Plain English for the log (this module has no string catalog); the app shows a localized text.
    public var description: String { "\(command): the pane is still opening (\(reference)); not sent" }
    /// The person's sentence in English, with no id (`DaemonService.paneNotReadyText` replaces it with the app's).
    public var reason: String { "This pane is still opening; try again in a moment." }
}
