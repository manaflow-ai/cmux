import CmuxRemoteSession
import Foundation

@MainActor
extension RemoteTmuxControlConnection {
    /// The most history bytes one full-history seed holds. The rest of a seed's
    /// snapshot budget (``maximumPaneSeedSnapshotBytes``) is left for the screen capture.
    nonisolated static let maximumFullHistoryBytes = maximumPaneSeedSnapshotBytes - 4 * 1_024 * 1_024

    /// The `display-message` line that reads a pane's history length, width and screen.
    nonisolated static func paneHistoryShapeQueryCommand(paneId: Int) -> String {
        "display-message -p -t %\(paneId) -F \"\(RemoteTmuxPaneHistoryShape.format)\""
    }

    /// The capture of a pane's newest `rows` history rows that measures its row size.
    nonisolated static func paneHistorySampleCommand(paneId: Int, rows: Int) -> String {
        "capture-pane -p -e -S -\(rows) -E -1 -t %\(paneId)"
    }

    /// Repaints a mirrored pane with its whole tmux history, so the surface's own
    /// find and copy mode can reach rows older than the attach seed.
    ///
    /// The attach seed reads the newest 5,000 rows in one capture. This reads the
    /// pane's history length first, and captures a few of its newest rows to measure
    /// how many bytes a row takes. Then it sends one tmux command queue: pause this
    /// client's output for the pane, read the history in bounded chunks (see
    /// ``RemoteTmuxPaneHistoryPlan``), read the screen and terminal state, and resume.
    /// tmux runs a queue without reading the pane in between, so the history, the
    /// screen and the live output after it line up exactly as they do for the
    /// attach seed. The surface's scrollback is cleared and refilled in one paint.
    ///
    /// tmux answers the whole queue back to back, so the queue asks only for the newest
    /// rows the seed is expected to keep (``RemoteTmuxFullHistorySeedState/byteBudget``)
    /// at the measured row size. A long, wide or colorful history then cannot send many
    /// times what the seed keeps through the stdout bridge.
    ///
    /// Nothing is sent for a pane on the alternate screen, which has no history.
    func reseedPaneWithFullHistory(paneId: Int) async -> RemoteTmuxFullHistorySeedOutcome {
        guard connectionState == .connected else { return .failed }
        let reply = await queryOutcomeWithTimeout(
            Self.paneHistoryShapeQueryCommand(paneId: paneId),
            timeout: 15
        )
        guard let line = reply.lines?.first,
              let shape = RemoteTmuxPaneHistoryShape(reply: line) else { return .failed }
        if shape.isAlternateScreen { return .alternateScreen }
        let sampleRows = RemoteTmuxPaneHistoryPlan.sampleRows(
            historySize: shape.historySize,
            paneWidth: shape.paneWidth
        )
        // An empty sample measures nothing, so plan for the densest output a row can hold.
        var bytesPerRow = shape.paneWidth * RemoteTmuxPaneHistoryPlan.maximumEncodedBytesPerCell + 2
        if sampleRows > 0 {
            guard let sample = await queryOutcomeWithTimeout(
                Self.paneHistorySampleCommand(paneId: paneId, rows: sampleRows),
                timeout: 15
            ).lines else { return .failed }
            bytesPerRow = RemoteTmuxPaneHistoryPlan.bytesPerRow(sampledRows: sample) ?? bytesPerRow
        }
        let plan = RemoteTmuxPaneHistoryPlan(
            historySize: shape.historySize,
            paneWidth: shape.paneWidth,
            maximumCommandBlockBytes: RemoteTmuxControlStreamParser.defaultMaximumCommandBlockBytes,
            maximumBytes: fullHistorySeeds.byteBudget,
            bytesPerRow: bytesPerRow
        )
        return await withCheckedContinuation { continuation in
            let started = startFullHistorySeed(paneId: paneId, plan: plan, bytesPerRow: bytesPerRow) { painted in
                guard let painted else { return continuation.resume(returning: .failed) }
                // A full-screen app started after the shape query: the screen was painted,
                // and there was no scrollback to paint the history into.
                if painted.onAlternateScreen { return continuation.resume(returning: .alternateScreen) }
                continuation.resume(
                    returning: .loaded(
                        historyRows: painted.historyRows,
                        truncated: plan.isTruncated || painted.droppedRows > 0
                    )
                )
            }
            if !started { continuation.resume(returning: .failed) }
        }
    }

    /// Sends the full-history seed queue. Returns false, without calling
    /// `completion`, when no seed could start; otherwise `completion` fires exactly
    /// once when the seed is painted or abandoned.
    private func startFullHistorySeed(
        paneId: Int,
        plan: RemoteTmuxPaneHistoryPlan,
        bytesPerRow: Int,
        completion: @escaping (RemoteTmuxPaintedFullHistory?) -> Void
    ) -> Bool {
        guard connectionState == .connected,
              let seedID = beginPaneSeed(
                  paneId: paneId,
                  clearScrollback: true,
                  kind: .fullHistory,
                  loadsHistory: true
              )
        else { return false }
        // Keyed by the seed id in the tracked-send table, so a stream reset fails
        // it with every other tracked block (``failPendingTrackedSends()``).
        trackedSendCompletions[seedID] = { [weak self] installed in
            let painted = self?.fullHistorySeeds.painted.removeValue(forKey: seedID)
            completion(installed ? painted : nil)
        }
        var commands = [
            Self.paneOutputPauseCommand(paneId: paneId),
            Self.paneAltScreenQueryCommand(paneId: paneId),
        ]
        var kinds: [CommandKind] = [
            .paneOutputReset(paneId, seedID),
            .paneAltScreen(paneId, seedID),
        ]
        for chunk in plan.chunks {
            commands.append("capture-pane -p -e \(chunk.captureArguments) -t %\(paneId)")
            kinds.append(.capturePaneHistory(paneId, seedID))
        }
        commands += [
            "capture-pane -p -e -t %\(paneId)",
            Self.paneStateQueryCommand(paneId: paneId),
            Self.paneOutputContinueCommand(paneId: paneId),
        ]
        kinds += [
            .capturePane(paneId, seedID),
            .paneState(paneId, seedID),
            .paneOutputContinue(paneId, seedID),
        ]
        record(
            "pane-full-history-seed %\(paneId) rows=\(plan.historyRows) chunks=\(plan.chunks.count)"
                + " row-bytes=\(bytesPerRow)"
        )
        if !sendCommandQueueInternal(commands, kinds: kinds) {
            // A refused write may already have reset the stream, which resolves the
            // completion; both calls below are no-ops in that case.
            cancelPaneSeed(paneId: paneId, seedID: seedID)
            resolveFullHistorySeed(seedID, painted: nil)
        }
        return true
    }

    /// Adds one chunk of history rows to a full-history seed whose screen capture
    /// has not arrived yet.
    ///
    /// Chunks arrive oldest first. Once the rows pass ``fullHistorySeeds.byteBudget`` the
    /// oldest are dropped, so the seed keeps the newest rows that fit and the consumer
    /// can still deliver it. A chunk the pending-seed budget cannot hold ends the seed:
    /// painting the screen without it would leave a hole in the history.
    func appendPaneSeedHistory(paneId: Int, seedID: UUID, lines: [String]) {
        guard !lines.isEmpty,
              pendingPaneSeeds[paneId]?.first?.id == seedID,
              pendingPaneSeeds[paneId]?.first?.isCaptureInstalled == false,
              pendingPaneSeeds[paneId]?.first?.isOnAlternateScreen == false else { return }
        var rows = lines.map { line -> Data in
            var row = Data(line.utf8)
            row.append(contentsOf: [0x0d, 0x0a])
            return row
        }
        var incoming = rows.reduce(0) { $0 + $1.count }
        var dropped = 0
        while incoming > fullHistorySeeds.byteBudget, !rows.isEmpty {
            incoming -= rows.removeFirst().count
            dropped += 1
        }
        guard reservePendingPaneSeedBytes(incoming, paneId: paneId) else {
            if pendingPaneSeeds[paneId]?.first?.id == seedID {
                recoverPaneSeedBudget(paneId: paneId, event: "pane-full-history-seed-overflow")
            }
            return
        }
        pendingPaneSeeds[paneId]![0].historyRows.append(contentsOf: rows)
        pendingPaneSeeds[paneId]![0].historyByteCount += incoming
        pendingPaneSeeds[paneId]![0].droppedHistoryRows += dropped
        var released = 0
        var oldest = 0
        while pendingPaneSeeds[paneId]![0].historyByteCount - released > fullHistorySeeds.byteBudget {
            released += pendingPaneSeeds[paneId]![0].historyRows[oldest].count
            oldest += 1
        }
        guard oldest > 0 else { return }
        pendingPaneSeeds[paneId]![0].historyRows.removeFirst(oldest)
        pendingPaneSeeds[paneId]![0].historyByteCount -= released
        pendingPaneSeeds[paneId]![0].droppedHistoryRows += oldest
        releasePendingPaneSeedBytes(released)
    }

    /// A full-history load whose pane is on the alternate screen by the time tmux runs its
    /// queue. The alternate screen has no scrollback, so history rows painted onto it would
    /// be lost; they are left out, and so is the scrollback clear, which would only erase
    /// the rows the surface already holds. The screen capture still paints, because the
    /// queue paused the pane's output and the seed is how that screen arrives.
    func leavePaneSeedHistoryOutForAlternateScreen(paneId: Int, seedID: UUID) {
        guard pendingPaneSeeds[paneId]?.first?.id == seedID,
              pendingPaneSeeds[paneId]?.first?.loadsHistory == true,
              pendingPaneSeeds[paneId]?.first?.isCaptureInstalled == false else { return }
        // Only the reset is in the snapshot yet: the alternate-screen reply is the first
        // result after the pause, and the capture installs the screen's own clear.
        releasePendingPaneSeedBytes(pendingPaneSeeds[paneId]![0].snapshot.count)
        pendingPaneSeeds[paneId]![0].snapshot = Data()
        pendingPaneSeeds[paneId]![0].isOnAlternateScreen = true
    }

    /// Fires a waiting full-history load's completion once: with what was painted,
    /// or nil when the seed ended without painting.
    func resolveFullHistorySeed(_ seedID: UUID, painted: RemoteTmuxPaintedFullHistory?) {
        guard let completion = trackedSendCompletions.removeValue(forKey: seedID) else { return }
        if let painted { fullHistorySeeds.painted[seedID] = painted }
        completion(painted != nil)
    }
}
