import CmuxRemoteSession
import Foundation

@MainActor
extension RemoteTmuxControlConnection {
    /// The `display-message` line that reads a pane's history length, width and screen.
    nonisolated static func paneHistoryShapeQueryCommand(paneId: Int) -> String {
        "display-message -p -t %\(paneId) -F \"\(RemoteTmuxPaneHistoryShape.format)\""
    }

    /// Repaints a mirrored pane with its whole tmux history, so the surface's own
    /// find and copy mode can reach rows older than the attach seed.
    ///
    /// The attach seed reads the newest 5,000 rows in one capture. This reads the
    /// pane's history length first, then sends one tmux command queue: pause this
    /// client's output for the pane, read the history in bounded chunks (see
    /// ``RemoteTmuxPaneHistoryPlan``), read the screen and terminal state, and resume.
    /// tmux runs a queue without reading the pane in between, so the history, the
    /// screen and the live output after it line up exactly as they do for the
    /// attach seed. The surface's scrollback is cleared and refilled in one paint.
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
        let plan = RemoteTmuxPaneHistoryPlan(historySize: shape.historySize, paneWidth: shape.paneWidth)
        return await withCheckedContinuation { continuation in
            let started = startFullHistorySeed(paneId: paneId, plan: plan) { installed in
                continuation.resume(
                    returning: installed
                        ? .loaded(historyRows: plan.historyRows, truncated: plan.isTruncated)
                        : .failed
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
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        guard connectionState == .connected,
              let seedID = beginPaneSeed(paneId: paneId, clearScrollback: true, kind: .fullHistory)
        else { return false }
        // Keyed by the seed id in the tracked-send table, so a stream reset fails
        // it with every other tracked block (``failPendingTrackedSends()``).
        trackedSendCompletions[seedID] = completion
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
        record("pane-full-history-seed %\(paneId) rows=\(plan.historyRows) chunks=\(plan.chunks.count)")
        if !sendCommandQueueInternal(commands, kinds: kinds) {
            // A refused write may already have reset the stream, which resolves the
            // completion; both calls below are no-ops in that case.
            cancelPaneSeed(paneId: paneId, seedID: seedID)
            resolveFullHistorySeed(seedID, installed: false)
        }
        return true
    }

    /// Fires a waiting full-history load's completion once.
    func resolveFullHistorySeed(_ seedID: UUID, installed: Bool) {
        trackedSendCompletions.removeValue(forKey: seedID)?(installed)
    }
}
