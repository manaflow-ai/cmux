import CmuxRemoteSession
import Foundation

@MainActor
extension RemoteTmuxControlConnection {
    /// Live output retained around one capture boundary. This is deliberately
    /// separate from the parser's larger command-block budget: a valid capture
    /// must not be rejected merely because it contains more than 8 MiB of history.
    nonisolated static let maximumPendingPaneSeedLiveBytes = 8 * 1_024 * 1_024
    /// Capture output can consume the parser's entire command-block allowance;
    /// reserve a small fixed amount for the clear/alt-screen framing added locally.
    nonisolated static let maximumPaneSeedSnapshotBytes =
        RemoteTmuxControlStreamParser.defaultMaximumCommandBlockBytes + 64 * 1_024
    /// Consumer retention includes one maximum snapshot and its bounded live catch-up.
    nonisolated static let maximumPendingPaneSeedDeliveryBytes =
        maximumPaneSeedSnapshotBytes + maximumPendingPaneSeedLiveBytes
    nonisolated static let maximumConcurrentReconnectPaneSeeds = 2
    nonisolated static let maximumPendingPaneSeedBytes =
        maximumPendingPaneSeedDeliveryBytes * maximumConcurrentReconnectPaneSeeds

    func beginPaneSeed(
        paneId: Int,
        clearScrollback: Bool,
        kind: RemoteTmuxPaneSeedKind
    ) -> UUID? {
        let id = UUID()
        let reset = clearScrollback
            ? Data("\u{1b}[H\u{1b}[2J\u{1b}[3J".utf8)
            : Data()
        guard reservePendingPaneSeedBytes(reset.count, paneId: paneId) else { return nil }
        pendingPaneSeeds[paneId, default: []].append(
            RemoteTmuxPendingPaneSeed(id: id, kind: kind, snapshot: reset)
        )
        return id
    }

    func cancelPaneSeed(paneId: Int, seedID: UUID) {
        guard var seeds = pendingPaneSeeds[paneId],
              let index = seeds.firstIndex(where: { $0.id == seedID }) else { return }
        let removed = seeds.remove(at: index)
        releasePendingPaneSeedBytes(removed.retainedByteCount)
        pendingPaneSeeds[paneId] = seeds.isEmpty ? nil : seeds
        completePaneSeedLifecycle(paneId: paneId, seedID: seedID)
    }

    func appendPaneSeedPrefix(paneId: Int, seedID: UUID, data: Data) {
        guard !data.isEmpty,
              pendingPaneSeeds[paneId]?.first?.id == seedID,
              pendingPaneSeeds[paneId]?.first?.isCaptureInstalled == false else { return }
        guard reservePendingPaneSeedBytes(data.count, paneId: paneId) else { return }
        pendingPaneSeeds[paneId]![0].snapshot.append(data)
    }

    func installPaneSeedCapture(paneId: Int, seedID: UUID, data: Data) {
        guard pendingPaneSeeds[paneId]?.first?.id == seedID,
              pendingPaneSeeds[paneId]?.first?.isCaptureInstalled == false else { return }
        guard reservePendingPaneSeedBytes(data.count, paneId: paneId) else { return }
        pendingPaneSeeds[paneId]![0].snapshot.append(data)
        pendingPaneSeeds[paneId]![0].isCaptureInstalled = true
    }

    /// Absorbs live bytes until the capture/state transaction resolves. Bytes
    /// before the capture result are covered by the snapshot; bytes after it are
    /// retained for exactly-once catch-up.
    func absorbPaneOutputIntoPendingSeed(paneId: Int, data: Data) -> Bool {
        guard !data.isEmpty, pendingPaneSeeds[paneId]?.isEmpty == false else { return false }
        let nextCount = pendingPaneSeeds[paneId]![0].bufferedLiveByteCount + data.count
        guard nextCount <= Self.maximumPendingPaneSeedLiveBytes,
              reservePendingPaneSeedBytes(data.count, paneId: paneId) else {
            recoverPaneSeedBudget(paneId: paneId, event: "pane-seed-backpressure")
            return true
        }
        pendingPaneSeeds[paneId]![0].bufferedLiveByteCount = nextCount
        if pendingPaneSeeds[paneId]![0].isCaptureInstalled {
            Self.appendCoalesced(data, to: &pendingPaneSeeds[paneId]![0].catchUpOutput)
        } else {
            Self.appendCoalesced(data, to: &pendingPaneSeeds[paneId]![0].discardedOutput)
        }
        return true
    }

    func routePaneOutput(paneId: Int, data: Data) {
        guard !absorbPaneOutputIntoPendingSeed(paneId: paneId, data: data) else { return }
        observers.emitPaneOutput(paneId, data)
    }

    func finishPaneSeed(paneId: Int, seedID: UUID, state: Data) {
        guard var seeds = pendingPaneSeeds[paneId], seeds.first?.id == seedID else { return }
        let completed = seeds.removeFirst()
        releasePendingPaneSeedBytes(completed.retainedByteCount)
        pendingPaneSeeds[paneId] = seeds.isEmpty ? nil : seeds
        defer { completePaneSeedLifecycle(paneId: paneId, seedID: seedID) }
        guard completed.isCaptureInstalled else {
            emitBufferedPaneOutput(completed, paneId: paneId)
            return
        }
        observers.emitPaneSeed(
            paneId,
            RemoteTmuxPaneSeed(
                kind: completed.kind,
                discardedOutput: completed.discardedOutput,
                snapshot: completed.snapshot,
                catchUpOutput: completed.catchUpOutput,
                state: state
            )
        )
    }

    func failPaneSeedCommand(_ kind: CommandKind, errorLines: [String]) {
        let paneId: Int
        let seedID: UUID
        switch kind {
        case let .paneOutputReset(id, token),
             let .paneOutputContinue(id, token),
             let .capturePane(id, token),
             let .paneState(id, token):
            paneId = id
            seedID = token
        case .paneAltScreen:
            return
        default:
            return
        }
        // `.paneState` completes and removes the local seed before tmux executes
        // the final `continue` command in the same queue. A failed continue must
        // therefore reconnect even when there is no pending seed left to find:
        // this control client's pane-output cursor is still paused and cannot be
        // repaired by replaying any locally buffered bytes.
        if case .paneOutputContinue = kind {
            record("pane-seed-boundary-error %\(paneId)")
            beginReconnecting()
            return
        }
        guard var seeds = pendingPaneSeeds[paneId], seeds.first?.id == seedID else { return }
        // A short-lived pane can exit after a growth/layout event queued its
        // repaint but before tmux executes the capture. There is no surface left
        // to recover, so reconnecting the whole control client only disrupts the
        // surviving panes. Drop every seed for the vanished target and refresh
        // topology; unknown boundary failures still reconnect below because their
        // snapshot/live ordering cannot be proven safe.
        if errorLines.joined(separator: " ")
            .localizedCaseInsensitiveContains("find pane")
        {
            record("pane-seed-target-gone %\(paneId)")
            discardPendingPaneSeeds(paneId: paneId)
            requestWindows()
            return
        }
        // Once this client's cursor was reset, replaying buffered bytes after a
        // failed capture would either duplicate the grid or lose the reset backlog.
        // A fresh control client is the only authoritative recovery. The reset
        // itself failing has the same answer: do not continue a seed whose boundary
        // the server did not establish.
        switch kind {
        case .paneOutputReset, .capturePane:
            record("pane-seed-boundary-error %\(paneId)")
            beginReconnecting()
            return
        default:
            break
        }
        let failed = seeds.removeFirst()
        releasePendingPaneSeedBytes(failed.retainedByteCount)
        pendingPaneSeeds[paneId] = seeds.isEmpty ? nil : seeds
        defer { completePaneSeedLifecycle(paneId: paneId, seedID: seedID) }
        switch kind {
        case .paneState where failed.isCaptureInstalled:
            observers.emitPaneSeed(
                paneId,
                RemoteTmuxPaneSeed(
                    kind: failed.kind,
                    discardedOutput: failed.discardedOutput,
                    snapshot: failed.snapshot,
                    catchUpOutput: failed.catchUpOutput,
                    state: Data()
                )
            )
        case .paneState:
            emitBufferedPaneOutput(failed, paneId: paneId)
        default:
            break
        }
    }

    func discardPendingPaneSeeds() {
        pendingPaneSeeds.removeAll(keepingCapacity: false)
        pendingPaneSeedByteCount = 0
        pendingPaneVisibleRepaintSeedIDs.removeAll(keepingCapacity: false)
        deferredPaneVisibleRepaints.removeAll(keepingCapacity: false)
        pendingReconnectSeedIDs.removeAll(keepingCapacity: false)
        pendingReconnectPaneIDs.removeAll(keepingCapacity: false)
    }

    func discardPendingPaneSeeds(keeping livePanes: Set<Int>) {
        let removedSeedIDs = pendingPaneSeeds
            .filter { !livePanes.contains($0.key) }
            .flatMap { $0.value.map(\.id) }
        let removedByteCount = pendingPaneSeeds
            .filter { !livePanes.contains($0.key) }
            .values.flatMap { $0 }.reduce(0) { $0 + $1.retainedByteCount }
        pendingPaneSeeds = pendingPaneSeeds.filter { livePanes.contains($0.key) }
        releasePendingPaneSeedBytes(removedByteCount)
        pendingPaneVisibleRepaintSeedIDs = pendingPaneVisibleRepaintSeedIDs.filter {
            livePanes.contains($0.key)
        }
        deferredPaneVisibleRepaints.formIntersection(livePanes)
        pendingReconnectPaneIDs.removeAll { !livePanes.contains($0) }
        for seedID in removedSeedIDs { resolveReconnectSeed(seedID) }
    }

    func discardPendingPaneSeeds(paneId: Int) {
        let removedSeeds = pendingPaneSeeds.removeValue(forKey: paneId) ?? []
        let removedSeedIDs = removedSeeds.map(\.id)
        releasePendingPaneSeedBytes(removedSeeds.reduce(0) { $0 + $1.retainedByteCount })
        pendingPaneVisibleRepaintSeedIDs[paneId] = nil
        deferredPaneVisibleRepaints.remove(paneId)
        pendingReconnectPaneIDs.removeAll { $0 == paneId }
        for seedID in removedSeedIDs { resolveReconnectSeed(seedID) }
    }

    private func completePaneSeedLifecycle(paneId: Int, seedID: UUID) {
        let gatesReconnectReady = pendingReconnectSeedIDs.contains(seedID)
        let completedVisibleRepaint = pendingPaneVisibleRepaintSeedIDs[paneId] == seedID
        if completedVisibleRepaint { pendingPaneVisibleRepaintSeedIDs[paneId] = nil }
        let followUpSeedID = completedVisibleRepaint
            ? startDeferredPaneVisibleRepaintIfNeeded(paneId: paneId)
            : nil
        if gatesReconnectReady,
           connectionState == .connected,
           let followUpSeedID
        {
            pendingReconnectSeedIDs.insert(followUpSeedID)
        }
        resolveReconnectSeed(seedID)
    }

    private func startDeferredPaneVisibleRepaintIfNeeded(paneId: Int) -> UUID? {
        guard deferredPaneVisibleRepaints.remove(paneId) != nil else { return nil }
        guard connectionState == .connected else { return nil }
        return repaintPaneVisibleScreen(paneId: paneId)
    }

    func resolveReconnectSeed(_ seedID: UUID) {
        guard pendingReconnectSeedIDs.remove(seedID) != nil else { return }
        pumpReconnectPaneSeeds()
        notifyReconnectReadyIfSeedBatchDrained()
    }

    func notifyReconnectReadyIfSeedBatchDrained() {
        guard connectionState == .connected,
              pendingReconnectSeedIDs.isEmpty,
              pendingReconnectPaneIDs.isEmpty else { return }
        // Reconnect readiness follows an authoritative full-history seed. Do not
        // run the first-attach rows-minus-one redraw kick here: its shrink moves
        // the first visible primary-screen row into local scrollback, and the
        // restore repaint would duplicate that row at the viewport boundary.
        observers.notifyReconnectReady()
    }

    func pumpReconnectPaneSeeds() {
        guard connectionState == .connected else { return }
        while pendingReconnectSeedIDs.count < Self.maximumConcurrentReconnectPaneSeeds,
              !pendingReconnectPaneIDs.isEmpty
        {
            let paneId = pendingReconnectPaneIDs.removeFirst()
            guard paneIsLive(paneId) else { continue }
            guard let seedID = seedPane(paneId: paneId, clearScrollback: true) else {
                guard connectionState == .connected else { return }
                // A live pane must never silently fall out of the reconnect
                // barrier. The normal budget/write failures already reconnect;
                // preserve that invariant if a future rejection path leaves the
                // connection nominally live as well.
                pendingReconnectPaneIDs.insert(paneId, at: 0)
                beginReconnecting()
                return
            }
            pendingReconnectSeedIDs.insert(seedID)
        }
    }

    private func paneIsLive(_ paneId: Int) -> Bool {
        windowsByID.values.contains { $0.paneIDsInOrder.contains(paneId) }
    }

    private static func appendCoalesced(_ data: Data, to chunks: inout [Data]) {
        if chunks.isEmpty {
            chunks.append(data)
        } else {
            chunks[chunks.index(before: chunks.endIndex)].append(data)
        }
    }

    /// Recovers one pane after the producer ran out of seed budget.
    ///
    /// A budget ceiling is not a transport failure. Both call sites used to reach for
    /// ``beginReconnecting()`` under an explicit `connectionState == .connected` guard — a healthy
    /// stream restarted because a renderer could not keep up — and the reattach then reseeds EVERY pane
    /// with `clearScrollback`, emitting ESC[3J, so one slow pane truncated every sibling's scrollback.
    /// Under one shared stream per host that reaches every session on the machine, not one.
    ///
    /// Dropping this pane's retained bytes is safe because the re-seed is an authoritative
    /// `capture-pane`: the content is re-derived from tmux's own grid rather than remembered. Freeing
    /// them first is also what makes room for the re-seed to be admitted.
    private func recoverPaneSeedBudget(paneId: Int, event: String) {
        record("\(event) %\(paneId)")
        // Freeing this pane's retained bytes is the urgent half and is safe to do here.
        discardPendingPaneSeeds(paneId: paneId)
        // The re-seed is NOT. This runs inside the reservation that just failed, and seeding re-enters
        // that same reservation — calling it synchronously recurses until the stack overflows, which is
        // what a fuzz run measured. Handing it to the next main-actor turn breaks the cycle, and by then
        // the discard above has already made room.
        Task { @MainActor [weak self] in
            guard let self, !self.exited else { return }
            _ = self.seedPane(paneId: paneId, clearScrollback: true)
        }
    }

    private func reservePendingPaneSeedBytes(_ count: Int, paneId: Int) -> Bool {
        guard count >= 0,
              count <= pendingPaneSeedByteLimit,
              pendingPaneSeedByteCount <= pendingPaneSeedByteLimit - count else {
            recoverPaneSeedBudget(paneId: paneId, event: "pane-seed-total-backpressure")
            return false
        }
        pendingPaneSeedByteCount += count
        return true
    }

    private func releasePendingPaneSeedBytes(_ count: Int) {
        pendingPaneSeedByteCount = max(0, pendingPaneSeedByteCount - count)
    }

    /// Repaints panes whose verified tmux assignment grew since the last
    /// publication. A surface cannot recover cells that were clipped while its
    /// grid was shorter from the live PTY stream alone; `capture-pane` is the
    /// authoritative, transport-independent repair. New panes are excluded because
    /// their full-history seed owns their initial paint.
    func repaintPanesThatGrew(from previous: RemoteTmuxWindow?, to current: RemoteTmuxWindow) {
        guard let previous else { return }
        let previousLeaves = assignedPaneLeaves(in: previous)
        let currentLeaves = assignedPaneLeaves(in: current)
        let panes = currentLeaves.compactMap { paneId, leaf -> Int? in
            guard let old = previousLeaves[paneId],
                  leaf.width > old.width || leaf.height > old.height else { return nil }
            return paneId
        }
        for paneId in panes.sorted() { repaintPaneVisibleScreen(paneId: paneId) }
    }

    /// The grid each live surface renders: the visible zoom leaf wins, while
    /// hidden panes retain their base-layout assignments.
    private func assignedPaneLeaves(in window: RemoteTmuxWindow) -> [Int: RemoteTmuxLayoutNode] {
        var leaves = window.layout.leavesByPaneID
        if window.zoomed, let visible = window.visibleLayout?.leavesByPaneID {
            for (paneId, leaf) in visible { leaves[paneId] = leaf }
        }
        return leaves
    }

    /// Fails every request whose reply belongs to the outgoing control stream.
    func failPendingCommandTransactions() {
        discardPendingPaneSeeds()
        failPendingActivityQueries()
        failPendingNewWindowRequests()
        failPendingWindowReorderVerifications()
        failPendingTrackedSends()
    }

    private func emitBufferedPaneOutput(_ seed: RemoteTmuxPendingPaneSeed, paneId: Int) {
        for data in seed.discardedOutput { observers.emitPaneOutput(paneId, data) }
        for data in seed.catchUpOutput { observers.emitPaneOutput(paneId, data) }
    }
}
