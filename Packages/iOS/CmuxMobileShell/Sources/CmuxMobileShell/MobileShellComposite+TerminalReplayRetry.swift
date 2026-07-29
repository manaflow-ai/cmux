import Foundation
internal import CmuxMobileDiagnostics

/// Retry accounting for the pending-input render-grid drop path, layered on
/// the replay failure-retry counter owned by
/// `MobileShellComposite+TerminalReplayLifecycle.swift` (which holds the
/// barrier-token `prepareTerminalReplayFailureRetry` and the exhaustion
/// check). This file adds the non-barrier variant used when a live-event
/// replay comes back stale, the drop-path request gate, and the no-progress
/// budget consumption that keeps that gate bounded.
extension MobileShellComposite {
    func prepareNonBarrierTerminalReplayFailureRetry(surfaceID: String) -> Bool {
        guard remoteClient != nil else { return false }
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

    func requestTerminalReplayAfterDroppedRenderGrid(surfaceID: String, source: String) {
        guard !terminalReplayFailureRetryExhausted(surfaceID: surfaceID) else {
            MobileDebugLog.anchormux(
                "CMUX_REPLAY retry_exhausted_after_drop source=\(source) surface=\(surfaceID)"
            )
            // Same fail-open invariant as failOpenTerminalReplayBarrier: once
            // retry budget is exhausted, the pending-input gate must not keep
            // live output suppressed forever.
            pendingTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
            pendingTerminalInputDroppedRenderGridSurfaceIDs.remove(surfaceID)
            terminalReplayFailureRetryCountsBySurfaceID.removeValue(forKey: surfaceID)
            return
        }
        requestTerminalReplay(surfaceID: surfaceID)
    }

    @discardableResult
    func recoverAfterDroppedReplayFrame(
        surfaceID: String,
        replayBarrierToken: UUID?,
        replayRequestID: UUID,
        coveredReplayBarrierDroppedOutputCount: UInt64?,
        reason: String
    ) -> Bool {
        let retryBudgetWasExhausted = terminalReplayFailureRetryExhausted(surfaceID: surfaceID)
        if let retryToken = prepareTerminalReplayFailureRetry(
            surfaceID: surfaceID,
            replayBarrierToken: replayBarrierToken
        ) {
            clearTerminalReplayInFlightIfCurrent(surfaceID: surfaceID, requestID: replayRequestID)
            requestTerminalReplay(
                surfaceID: surfaceID,
                replayBarrierToken: retryToken,
                coveredReplayBarrierDroppedOutputCount: coveredReplayBarrierDroppedOutputCount
                    ?? terminalReplayBarrierDroppedOutputCountsBySurfaceID[surfaceID]
            )
            return true
        }
        if replayBarrierToken == nil,
           prepareNonBarrierTerminalReplayFailureRetry(surfaceID: surfaceID) {
            clearTerminalReplayInFlightIfCurrent(surfaceID: surfaceID, requestID: replayRequestID)
            requestTerminalReplay(surfaceID: surfaceID)
            return true
        }
        let retryBudgetExhausted = retryBudgetWasExhausted
            || terminalReplayFailureRetryExhausted(surfaceID: surfaceID)
        let barrierFailedOpen = replayBarrierToken.map {
            failOpenTerminalReplayBarrier(surfaceID: surfaceID, token: $0, reason: reason)
        } ?? false
        if retryBudgetExhausted {
            // Barrier fail-open clears counters because normal recovery should
            // get a fresh episode. This replay-response drop is still part of
            // the same pending-input episode, so keep its exhausted budget
            // spent until a new input target explicitly resets it.
            terminalReplayFailureRetryCountsBySurfaceID[surfaceID] = Self.maxTerminalReplayFailureRetries
        }
        if !barrierFailedOpen {
            failOpenPendingInputReplayGate(
                surfaceID: surfaceID,
                reason: reason,
                resetRetryBudget: !retryBudgetExhausted
            )
        }
        return false
    }

    func failOpenPendingInputReplayGate(
        surfaceID: String,
        reason: String,
        resetRetryBudget: Bool = true
    ) {
        MobileDebugLog.anchormux("CMUX_REPLAY pending_input_fail_open surface=\(surfaceID) reason=\(reason)")
        pendingTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        pendingTerminalInputDroppedRenderGridSurfaceIDs.remove(surfaceID)
        if resetRetryBudget {
            terminalReplayFailureRetryCountsBySurfaceID.removeValue(forKey: surfaceID)
        }
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
}
