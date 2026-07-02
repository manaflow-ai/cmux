import Foundation
internal import CmuxMobileDiagnostics

extension MobileShellComposite {
    func prepareTerminalReplayFailureRetry(
        surfaceID: String,
        replayBarrierToken: UUID?
    ) -> UUID? {
        guard let replayBarrierToken,
              hasTerminalOutputSink(surfaceID: surfaceID),
              terminalReplayBarrierTokensBySurfaceID[surfaceID] == replayBarrierToken else {
            return nil
        }
        guard prepareTerminalReplayFailureRetry(surfaceID: surfaceID) else {
            return nil
        }
        return replayBarrierToken
    }

    func prepareNonBarrierTerminalReplayFailureRetry(surfaceID: String) -> Bool {
        guard remoteClient != nil else { return false }
        return prepareTerminalReplayFailureRetry(surfaceID: surfaceID)
    }

    func terminalReplayFailureRetryExhausted(surfaceID: String) -> Bool {
        (terminalReplayFailureRetryCountsBySurfaceID[surfaceID] ?? 0) >= Self.maxTerminalReplayFailureRetries
    }

    func requestTerminalReplayAfterDroppedRenderGrid(surfaceID: String, source: String) {
        guard !terminalReplayFailureRetryExhausted(surfaceID: surfaceID) else {
            MobileDebugLog.anchormux(
                "CMUX_REPLAY retry_exhausted_after_drop source=\(source) surface=\(surfaceID)"
            )
            return
        }
        requestTerminalReplay(surfaceID: surfaceID)
    }

    /// Consume one replay-failure attempt after a replay response made no
    /// progress toward the pending input target (empty response, bytes without
    /// a sequence, stale sequence, or a failed non-barrier request). Without
    /// this, the live-event drop path would re-arm a replay per delta forever
    /// against a host that keeps returning no-progress responses, since only
    /// stale render-grid responses advance the retry counter.
    func consumeTerminalReplayFailureRetryAfterNoProgress(surfaceID: String, reason: String) {
        guard pendingTerminalInputDroppedRenderGridSurfaceIDs.contains(surfaceID) else { return }
        let retryCount = terminalReplayFailureRetryCountsBySurfaceID[surfaceID] ?? 0
        guard retryCount < Self.maxTerminalReplayFailureRetries else { return }
        terminalReplayFailureRetryCountsBySurfaceID[surfaceID] = retryCount + 1
        MobileDebugLog.anchormux(
            "CMUX_REPLAY no_progress reason=\(reason) surface=\(surfaceID) attempt=\(retryCount + 1)"
        )
    }

    private func prepareTerminalReplayFailureRetry(surfaceID: String) -> Bool {
        guard hasTerminalOutputSink(surfaceID: surfaceID) else { return false }
        let retryCount = terminalReplayFailureRetryCountsBySurfaceID[surfaceID] ?? 0
        guard retryCount < Self.maxTerminalReplayFailureRetries else {
            MobileDebugLog.anchormux(
                "CMUX_REPLAY retry_exhausted surface=\(surfaceID) attempts=\(retryCount)"
            )
            return false
        }
        terminalReplayFailureRetryCountsBySurfaceID[surfaceID] = retryCount + 1
        MobileDebugLog.anchormux(
            "CMUX_REPLAY retry_after_failure surface=\(surfaceID) attempt=\(retryCount + 1)"
        )
        return true
    }
}
