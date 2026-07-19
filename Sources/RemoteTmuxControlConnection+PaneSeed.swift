import Foundation

@MainActor
extension RemoteTmuxControlConnection {
    /// Seed buffering is normally one control-channel round trip. Bound it so a
    /// stalled command behind a flooding pane cannot grow memory indefinitely;
    /// reconnecting re-establishes both parser order and an authoritative seed.
    private static let maximumPendingPaneSeedLiveBytes = 8 * 1_024 * 1_024

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
        guard nextCount <= Self.maximumPendingPaneSeedLiveBytes else {
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

    func failPaneSeedCommand(_ kind: CommandKind) {
        let paneId: Int
        let seedID: UUID
        switch kind {
        case let .capturePane(id, token), let .paneState(id, token):
            paneId = id
            seedID = token
        case .paneAltScreen:
            return
        default:
            return
        }
        guard var seeds = pendingPaneSeeds[paneId], seeds.first?.id == seedID else { return }
        let failed = seeds.removeFirst()
        pendingPaneSeeds[paneId] = seeds.isEmpty ? nil : seeds
        switch kind {
        case .capturePane:
            emitBufferedPaneOutput(failed, paneId: paneId)
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
    }

    func discardPendingPaneSeeds(keeping livePanes: Set<Int>) {
        pendingPaneSeeds = pendingPaneSeeds.filter { livePanes.contains($0.key) }
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
