import CmuxRemoteSession
import Foundation

@MainActor
extension RemoteTmuxControlConnection {
    /// Seed buffering is normally one control-channel round trip. Bound it so a
    /// stalled command behind a flooding pane cannot grow memory indefinitely;
    /// reconnecting re-establishes both parser order and an authoritative seed.
    static let maximumPendingPaneSeedBytes = 8 * 1_024 * 1_024

    func beginPaneSeed(paneId: Int, clearScrollback: Bool) -> UUID {
        let id = UUID()
        let reset = clearScrollback
            ? Data("\u{1b}[H\u{1b}[2J\u{1b}[3J".utf8)
            : Data()
        pendingPaneSeeds[paneId, default: []].append(
            RemoteTmuxPendingPaneSeed(id: id, snapshot: reset)
        )
        return id
    }

    func cancelPaneSeed(paneId: Int, seedID: UUID) {
        guard var seeds = pendingPaneSeeds[paneId],
              let index = seeds.firstIndex(where: { $0.id == seedID }) else { return }
        seeds.remove(at: index)
        pendingPaneSeeds[paneId] = seeds.isEmpty ? nil : seeds
        completePaneSeedLifecycle(paneId: paneId, seedID: seedID)
    }

    func appendPaneSeedPrefix(paneId: Int, seedID: UUID, data: Data) {
        guard !data.isEmpty,
              pendingPaneSeeds[paneId]?.first?.id == seedID,
              pendingPaneSeeds[paneId]?.first?.isCaptureInstalled == false else { return }
        pendingPaneSeeds[paneId]![0].snapshot.append(data)
    }

    func installPaneSeedCapture(paneId: Int, seedID: UUID, data: Data) {
        guard pendingPaneSeeds[paneId]?.first?.id == seedID,
              pendingPaneSeeds[paneId]?.first?.isCaptureInstalled == false else { return }
        pendingPaneSeeds[paneId]![0].snapshot.append(data)
        pendingPaneSeeds[paneId]![0].isCaptureInstalled = true
    }

    /// Absorbs live bytes until the capture/state transaction resolves. Bytes
    /// before the capture result are covered by the snapshot; bytes after it are
    /// retained for exactly-once catch-up.
    func absorbPaneOutputIntoPendingSeed(paneId: Int, data: Data) -> Bool {
        guard !data.isEmpty, pendingPaneSeeds[paneId]?.isEmpty == false else { return false }
        let nextCount = pendingPaneSeeds[paneId]![0].bufferedLiveByteCount + data.count
        guard nextCount <= Self.maximumPendingPaneSeedBytes else {
            record("pane-seed-backpressure %\(paneId)")
            beginReconnecting()
            return true
        }
        pendingPaneSeeds[paneId]![0].bufferedLiveByteCount = nextCount
        if pendingPaneSeeds[paneId]![0].isCaptureInstalled {
            pendingPaneSeeds[paneId]![0].catchUpOutput.append(data)
        } else {
            pendingPaneSeeds[paneId]![0].discardedOutput.append(data)
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
        pendingPaneSeeds[paneId] = seeds.isEmpty ? nil : seeds
        defer { completePaneSeedLifecycle(paneId: paneId, seedID: seedID) }
        guard completed.isCaptureInstalled else {
            emitBufferedPaneOutput(completed, paneId: paneId)
            return
        }
        observers.emitPaneSeed(
            paneId,
            RemoteTmuxPaneSeed(
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
             let .capturePane(id, token),
             let .paneState(id, token):
            paneId = id
            seedID = token
        case .paneAltScreen:
            return
        default:
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
        pendingPaneSeeds[paneId] = seeds.isEmpty ? nil : seeds
        defer { completePaneSeedLifecycle(paneId: paneId, seedID: seedID) }
        switch kind {
        case .paneState where failed.isCaptureInstalled:
            observers.emitPaneSeed(
                paneId,
                RemoteTmuxPaneSeed(
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
        pendingPaneVisibleRepaintSeedIDs.removeAll(keepingCapacity: false)
        deferredPaneVisibleRepaints.removeAll(keepingCapacity: false)
        pendingReconnectSeedIDs.removeAll(keepingCapacity: false)
    }

    func discardPendingPaneSeeds(keeping livePanes: Set<Int>) {
        let removedSeedIDs = pendingPaneSeeds
            .filter { !livePanes.contains($0.key) }
            .flatMap { $0.value.map(\.id) }
        pendingPaneSeeds = pendingPaneSeeds.filter { livePanes.contains($0.key) }
        pendingPaneVisibleRepaintSeedIDs = pendingPaneVisibleRepaintSeedIDs.filter {
            livePanes.contains($0.key)
        }
        deferredPaneVisibleRepaints.formIntersection(livePanes)
        for seedID in removedSeedIDs { resolveReconnectSeed(seedID) }
    }

    func discardPendingPaneSeeds(paneId: Int) {
        let removedSeedIDs = pendingPaneSeeds.removeValue(forKey: paneId)?.map(\.id) ?? []
        pendingPaneVisibleRepaintSeedIDs[paneId] = nil
        deferredPaneVisibleRepaints.remove(paneId)
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
        notifyReconnectReadyIfSeedBatchDrained()
    }

    func notifyReconnectReadyIfSeedBatchDrained() {
        guard connectionState == .connected, pendingReconnectSeedIDs.isEmpty else { return }
        // Reconnect readiness follows an authoritative full-history seed. Do not
        // run the first-attach rows-minus-one redraw kick here: its shrink moves
        // the first visible primary-screen row into local scrollback, and the
        // restore repaint would duplicate that row at the viewport boundary.
        observers.notifyReconnectReady()
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
