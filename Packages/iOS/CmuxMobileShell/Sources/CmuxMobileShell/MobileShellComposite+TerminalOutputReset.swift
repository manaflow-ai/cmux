import CMUXMobileCore
internal import CmuxMobileDiagnostics
import CmuxMobileShellModel
public import Foundation

/// Render-pipeline reset and self-heal replay entrypoints for terminal output:
/// the surface-initiated reset (``MobileShellComposite/terminalOutputDidReset(surfaceID:streamToken:)``),
/// its ack-holding retry, and the pipeline-reset replay request
/// (``MobileShellComposite/terminalOutputNeedsReplay(surfaceID:)``).
/// Split from MobileShellComposite+TerminalOutputDelivery.swift to keep that
/// file inside the Swift file length budget.
extension MobileShellComposite {
    /// Abandon the current yielded terminal-output chunk after the local render
    /// surface reset. The abandoned bytes may have been applied to the old
    /// Ghostty surface or may still be behind a wedged worker queue, so continuing
    /// to drain the old pending queue would replay stale deltas into the rebuilt
    /// surface. Reset the queue, invalidate stale acks, then request a fresh
    /// authoritative replay from the Mac.
    public func terminalOutputDidReset(surfaceID: String, streamToken: UUID) {
        guard terminalOutputStreamTokensBySurfaceID[surfaceID] == streamToken,
              terminalOutputQueuesBySurfaceID[surfaceID] != nil else { return }
        if let replayBarrierToken = terminalReplayBarrierTokensBySurfaceID[surfaceID] {
            guard terminalReplayBarrierAckStreamTokensBySurfaceID[surfaceID] == streamToken else {
                // The barrier stays armed and keeps gating output, so the
                // stall is NOT recovered here; resolving would report a
                // still-frozen terminal as healthy and lose the episode's
                // start time.
                terminalReplayBarrierDroppedOutputSurfaceIDs.insert(surfaceID)
                MobileDebugLog.anchormux("terminal.output.reset_barrier_active surface=\(surfaceID)")
                return
            }
            terminalSyncDiagnostics.surfaceResolved(
                surface: Self.diagnosticSurfaceHandle(surfaceID),
                how: .manualRefresh,
                transport: terminalOutputTransport.debugName
            )
            retryTerminalReplayAfterAckReset(
                surfaceID: surfaceID,
                replayBarrierToken: replayBarrierToken
            )
            return
        }
        terminalSyncDiagnostics.surfaceResolved(
            surface: Self.diagnosticSurfaceHandle(surfaceID),
            how: .manualRefresh,
            transport: terminalOutputTransport.debugName
        )
        let replayBarrierToken = beginTerminalReplayBarrier(surfaceID: surfaceID, trigger: .barrier)
        // Rebuilt surface: nothing pre-barrier is visible anymore.
        rebaseTerminalReplayStaleFloor(surfaceID: surfaceID)
        terminalAlternateRenderGridBaselineSurfaceIDs.remove(surfaceID)
        MobileDebugLog.anchormux("terminal.output.reset surface=\(surfaceID)")
        requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: replayBarrierToken)
    }

    private func retryTerminalReplayAfterAckReset(
        surfaceID: String,
        replayBarrierToken: UUID
    ) {
        guard terminalReplayBarrierTokensBySurfaceID[surfaceID] == replayBarrierToken else {
            return
        }
        terminalOutputQueuesBySurfaceID[surfaceID] = TerminalOutputDeliveryQueue()
        terminalOutputStreamTokensBySurfaceID[surfaceID] = UUID()
        // Post-reset retry: rebuilt surface, so drop the floor, don't stash.
        rebaseTerminalReplayStaleFloor(surfaceID: surfaceID)
        deliveredTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        terminalAlternateRenderGridBaselineSurfaceIDs.remove(surfaceID)
        terminalFullReplacementSeqBySurfaceID.removeValue(forKey: surfaceID)
        terminalFullReplacementGenerationBySurfaceID.removeValue(forKey: surfaceID)
        pendingTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        pendingTerminalInputDroppedRenderGridSurfaceIDs.remove(surfaceID)
        terminalReplayBarrierAckStreamTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierAckCoveredDroppedOutputCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierTokensInFlightBySurfaceID.removeValue(forKey: surfaceID)
        guard let retryToken = prepareTerminalReplayFailureRetry(
            surfaceID: surfaceID,
            replayBarrierToken: replayBarrierToken
        ) else {
            preserveTerminalReplayBarrierIfCurrent(
                surfaceID: surfaceID,
                token: replayBarrierToken,
                reason: "reset_replay_ack"
            )
            return
        }
        MobileDebugLog.anchormux("terminal.output.reset_replay_ack surface=\(surfaceID)")
        requestTerminalReplay(
            surfaceID: surfaceID,
            replayBarrierToken: retryToken,
            coveredReplayBarrierDroppedOutputCount:
                terminalReplayBarrierDroppedOutputCountsBySurfaceID[surfaceID]
        )
    }

    /// Ask the Mac to replay the authoritative terminal state for a surface.
    /// Reached from the render-pipeline reset: the surface was rebuilt blank,
    /// so (like ``terminalOutputDidReset``) no pre-barrier baseline survives.
    public func terminalOutputNeedsReplay(surfaceID: String) {
        guard terminalByteContinuationsBySurfaceID[surfaceID] != nil else { return }
        recordTerminalManualRecovery(action: .renderReset, surfaceID: surfaceID)
        terminalSyncDiagnostics.surfaceResolved(
            surface: Self.diagnosticSurfaceHandle(surfaceID),
            how: .manualRefresh,
            transport: terminalOutputTransport.debugName
        )
        if let pendingAckToken = terminalViewportReplayBarrierPendingAckTokensBySurfaceID[surfaceID],
           terminalReplayBarrierTokensBySurfaceID[surfaceID] == pendingAckToken {
            // A pending viewport acknowledgement owns the next replay
            // decision. Beginning a fresh barrier here would drop the pending
            // token and let the acknowledgement dedupe its post-resize replay
            // against this pre-resize request; record the reset as owed
            // output so the acknowledgement's resolution replays instead.
            terminalReplayBarrierDroppedOutputSurfaceIDs.insert(surfaceID)
            MobileDebugLog.anchormux("terminal.output.replay_deferred_viewport_ack surface=\(surfaceID)")
            return
        }
        let replayBarrierToken = beginTerminalReplayBarrier(surfaceID: surfaceID, trigger: .barrier)
        rebaseTerminalReplayStaleFloor(surfaceID: surfaceID)
        terminalAlternateRenderGridBaselineSurfaceIDs.remove(surfaceID)
        MobileDebugLog.anchormux("terminal.output.replay_requested surface=\(surfaceID)")
        requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: replayBarrierToken)
    }
}
