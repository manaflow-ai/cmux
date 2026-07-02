import CMUXMobileCore
internal import CmuxMobileDiagnostics
import CmuxMobileShellModel
public import Foundation

extension MobileShellComposite {
    func claimTerminalReplayBarrierFollowUp(surfaceID: String) -> Bool {
        let followUpCount = terminalReplayBarrierFollowUpCountsBySurfaceID[surfaceID] ?? 0
        guard followUpCount < Self.maxTerminalReplayBarrierFollowUps else {
            MobileDebugLog.anchormux(
                "terminal.output.replay_followup_cap_reached surface=\(surfaceID) attempts=\(followUpCount)"
            )
            terminalReplayBarrierFollowUpCountsBySurfaceID.removeValue(forKey: surfaceID)
            return false
        }
        terminalReplayBarrierFollowUpCountsBySurfaceID[surfaceID] = followUpCount + 1
        return true
    }

    /// Yield a raw PTY byte chunk to the surface stream, if one is attached.
    @discardableResult
    func deliverTerminalBytes(
        _ bytes: Data,
        surfaceID: String,
        bypassReplayBarrier: Bool = false
    ) -> Bool {
        return deliverTerminalOutput(
            TerminalOutputDelivery(
                bytes: bytes,
                replaceable: false,
                viewportPolicy: .natural
            ),
            surfaceID: surfaceID,
            bypassReplayBarrier: bypassReplayBarrier
        )
    }

    @discardableResult
    func deliverTerminalRenderGrid(
        _ frame: MobileTerminalRenderGridFrame,
        surfaceID: String,
        bypassReplayBarrier: Bool = false
    ) -> Bool {
        return deliverTerminalOutput(
            TerminalOutputDelivery(
                renderGrid: frame,
                replaceable: frame.isReplaceableViewportPatchForMobileDelivery,
                viewportPolicy: frame.mobileViewportPolicy
            ),
            surfaceID: surfaceID,
            bypassReplayBarrier: bypassReplayBarrier
        )
    }

    func deliverTerminalViewportPolicy(_ policy: MobileTerminalOutputViewportPolicy, surfaceID: String) {
        _ = deliverTerminalOutput(
            TerminalOutputDelivery(
                bytes: Data(),
                replaceable: true,
                replacementScope: .viewportPolicy,
                viewportPolicy: policy
            ),
            surfaceID: surfaceID
        )
    }

    private func deliverTerminalOutput(
        _ delivery: TerminalOutputDelivery,
        surfaceID: String,
        bypassReplayBarrier: Bool = false
    ) -> Bool {
        guard let continuation = terminalByteContinuationsBySurfaceID[surfaceID],
              let streamToken = terminalOutputStreamTokensBySurfaceID[surfaceID] else { return false }
        if let replayBarrierToken = terminalReplayBarrierTokensBySurfaceID[surfaceID],
           !bypassReplayBarrier {
            terminalReplayBarrierDroppedOutputSurfaceIDs.insert(surfaceID)
            let droppedOutputCount = (terminalReplayBarrierDroppedOutputCountsBySurfaceID[surfaceID] ?? 0) &+ 1
            terminalReplayBarrierDroppedOutputCountsBySurfaceID[surfaceID] = droppedOutputCount
            if droppedOutputCount == 1 || droppedOutputCount.isMultiple(of: 32) {
                MobileDebugLog.anchormux(
                    "terminal.output.drop_replay_barrier surface=\(surfaceID) count=\(droppedOutputCount)"
                )
            }
            if remoteClient != nil,
               terminalReplayBarrierAckStreamTokensBySurfaceID[surfaceID] == nil,
               terminalViewportReplayBarrierPendingAckTokensBySurfaceID[surfaceID] == nil,
               !terminalReplaySurfaceIDsInFlight.contains(surfaceID),
               !terminalReplayFailureRetryExhausted(surfaceID: surfaceID) {
                MobileDebugLog.anchormux("terminal.output.replay_retry_after_drop surface=\(surfaceID)")
                requestTerminalReplay(
                    surfaceID: surfaceID,
                    replayBarrierToken: replayBarrierToken,
                    coveredReplayBarrierDroppedOutputCount: droppedOutputCount
                )
            }
            return false
        }
        var queue = terminalOutputQueuesBySurfaceID[surfaceID] ?? TerminalOutputDeliveryQueue()
        let immediate = queue.enqueue(delivery)
        let pendingCount = queue.pendingCount
        terminalOutputQueuesBySurfaceID[surfaceID] = queue
        if bypassReplayBarrier,
           immediate != nil,
           terminalReplayBarrierTokensBySurfaceID[surfaceID] != nil {
            terminalReplayBarrierAckStreamTokensBySurfaceID[surfaceID] = streamToken
        }
        if pendingCount >= 32, pendingCount.isMultiple(of: 32) {
            MobileDebugLog.anchormux(
                "terminal.output.pending surface=\(surfaceID) depth=\(pendingCount)"
            )
        }
        if let immediate {
            continuation.yield(
                MobileTerminalOutputChunk(
                    data: immediate.bytes,
                    streamToken: streamToken,
                    viewportPolicy: immediate.viewportPolicy
                )
            )
        }
        return true
    }

    /// Mark the current yielded terminal-output chunk as applied by the iOS surface.
    public func terminalOutputDidProcess(surfaceID: String, streamToken: UUID) {
        guard terminalOutputStreamTokensBySurfaceID[surfaceID] == streamToken,
              var queue = terminalOutputQueuesBySurfaceID[surfaceID] else { return }
        let next = queue.completeInFlight()
        terminalOutputQueuesBySurfaceID[surfaceID] = queue
        if terminalReplayBarrierAckStreamTokensBySurfaceID[surfaceID] == streamToken {
            let coveredDroppedOutputCount =
                terminalReplayBarrierAckCoveredDroppedOutputCountsBySurfaceID.removeValue(forKey: surfaceID)
            let currentDroppedOutputCount = terminalReplayBarrierDroppedOutputCountsBySurfaceID[surfaceID] ?? 0
            let needsFollowUpReplay = coveredDroppedOutputCount.map {
                currentDroppedOutputCount > $0
            } ?? true
            terminalReplayBarrierAckStreamTokensBySurfaceID.removeValue(forKey: surfaceID)
            terminalReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
            MobileDebugLog.anchormux("terminal.output.replay_barrier_cleared surface=\(surfaceID)")
            let droppedOutputDuringBarrier = terminalReplayBarrierDroppedOutputSurfaceIDs.remove(surfaceID) != nil
            terminalReplayBarrierDroppedOutputCountsBySurfaceID.removeValue(forKey: surfaceID)
            if droppedOutputDuringBarrier,
               needsFollowUpReplay,
               claimTerminalReplayBarrierFollowUp(surfaceID: surfaceID) {
                let replayBarrierToken = beginTerminalReplayBarrier(
                    surfaceID: surfaceID,
                    preservingFollowUpCount: true
                )
                MobileDebugLog.anchormux("terminal.output.replay_followup surface=\(surfaceID)")
                requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: replayBarrierToken)
                return
            }
            terminalReplayBarrierFollowUpCountsBySurfaceID.removeValue(forKey: surfaceID)
        }
        guard let next,
              let continuation = terminalByteContinuationsBySurfaceID[surfaceID],
              terminalOutputStreamTokensBySurfaceID[surfaceID] == streamToken else {
            return
        }
        continuation.yield(MobileTerminalOutputChunk(
            data: next.bytes,
            streamToken: streamToken,
            viewportPolicy: next.viewportPolicy
        ))
    }

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
                terminalReplayBarrierDroppedOutputSurfaceIDs.insert(surfaceID)
                MobileDebugLog.anchormux("terminal.output.reset_barrier_active surface=\(surfaceID)")
                return
            }
            retryTerminalReplayAfterAckReset(
                surfaceID: surfaceID,
                replayBarrierToken: replayBarrierToken
            )
            return
        }
        let replayBarrierToken = beginTerminalReplayBarrier(surfaceID: surfaceID)
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
        deliveredTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        pendingTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
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
    public func terminalOutputNeedsReplay(surfaceID: String) {
        guard terminalByteContinuationsBySurfaceID[surfaceID] != nil else { return }
        let replayBarrierToken = beginTerminalReplayBarrier(surfaceID: surfaceID)
        MobileDebugLog.anchormux("terminal.output.replay_requested surface=\(surfaceID)")
        requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: replayBarrierToken)
    }

}
