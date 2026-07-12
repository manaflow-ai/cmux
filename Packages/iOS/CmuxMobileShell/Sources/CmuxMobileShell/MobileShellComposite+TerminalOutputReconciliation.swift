import CMUXMobileCore
internal import CmuxMobileDiagnostics
import CmuxMobileShellModel
public import Foundation

extension MobileShellComposite {
    /// Claims a yielded chunk before the consumer queues any Ghostty work. A
    /// false result means a newer optimistic scroll discarded this unstarted
    /// viewport delivery and already advanced the output queue.
    public func terminalOutputWillProcess(
        surfaceID: String,
        streamToken: UUID,
        deliveryID: UUID
    ) -> Bool {
        guard terminalOutputStreamTokensBySurfaceID[surfaceID] == streamToken,
              var queue = terminalOutputQueuesBySurfaceID[surfaceID] else {
            return false
        }
        let claimed = queue.claimInFlight(deliveryID: deliveryID)
        terminalOutputQueuesBySurfaceID[surfaceID] = queue
        return claimed
    }

    func prepareTerminalOutputForOptimisticScroll(surfaceID: String) {
        guard var queue = terminalOutputQueuesBySurfaceID[surfaceID] else { return }
        let promoted = queue.discardUnclaimedForOptimisticScroll()
        terminalOutputQueuesBySurfaceID[surfaceID] = queue
        guard let promoted,
              let continuation = terminalByteContinuationsBySurfaceID[surfaceID],
              let streamToken = terminalOutputStreamTokensBySurfaceID[surfaceID] else {
            return
        }
        continuation.yield(MobileTerminalOutputChunk(
            data: promoted.bytes,
            streamToken: streamToken,
            deliveryID: promoted.deliveryID,
            viewportPolicy: promoted.viewportPolicy,
            scrollbackOffsetFromBottomRows: promoted.scrollbackOffsetFromBottomRows
        ))
    }

    func acceptTerminalRenderRevision(_ revision: UInt64, surfaceID: String) {
        acceptedTerminalRenderRevisionsBySurfaceID[surfaceID] = max(
            acceptedTerminalRenderRevisionsBySurfaceID[surfaceID] ?? 0,
            revision
        )
    }

    func deferTerminalRenderGridEvent(_ frame: MobileTerminalRenderGridFrame) {
        guard var deferred = deferredTerminalRenderGridEventsBySurfaceID[frame.surfaceID] else {
            deferredTerminalRenderGridEventsBySurfaceID[frame.surfaceID] = DeferredTerminalRenderGridEvent(
                frame: frame
            )
            return
        }
        deferred.append(frame)
        deferredTerminalRenderGridEventsBySurfaceID[frame.surfaceID] = deferred
    }

    func flushDeferredTerminalRenderGridEvent(surfaceID: String) {
        guard let deferred = deferredTerminalRenderGridEventsBySurfaceID.removeValue(forKey: surfaceID) else {
            return
        }
        guard !deferred.requiresReplay else {
            MobileDebugLog.anchormux("sync.render_grid_deferred_replay surface=\(surfaceID)")
            requestTerminalReplay(surfaceID: surfaceID)
            return
        }
        guard let frame = deferred.frame else { return }
        _ = deliverAuthoritativeTerminalRenderGrid(
            frame,
            expectedSurfaceID: surfaceID,
            source: "event"
        )
    }

    /// Flushes a deferred event before a gridless scroll acknowledgement raises
    /// the render-revision floor. The deferred entry is retained until delivery
    /// succeeds, so an equal-revision frame cannot be removed and then rejected.
    @discardableResult
    func completeGridlessTerminalScrollReconciliation(
        surfaceID: String,
        renderRevision: UInt64?
    ) -> Bool {
        if let deferred = deferredTerminalRenderGridEventsBySurfaceID[surfaceID] {
            if deferred.requiresReplay {
                deferredTerminalRenderGridEventsBySurfaceID.removeValue(forKey: surfaceID)
                if let renderRevision {
                    acceptTerminalRenderRevision(renderRevision, surfaceID: surfaceID)
                }
                MobileDebugLog.anchormux("sync.render_grid_deferred_replay surface=\(surfaceID)")
                requestTerminalReplay(surfaceID: surfaceID)
                return true
            }
            if let frame = deferred.frame {
                if let renderRevision,
                   frame.renderRevision.map({ $0 < renderRevision }) ?? true {
                    deferredTerminalRenderGridEventsBySurfaceID.removeValue(forKey: surfaceID)
                    acceptTerminalRenderRevision(renderRevision, surfaceID: surfaceID)
                    MobileDebugLog.anchormux(
                        "sync.render_grid_deferred_behind_ack surface=\(surfaceID) ack=\(renderRevision) deferred=\(frame.renderRevision ?? 0)"
                    )
                    requestTerminalReplay(surfaceID: surfaceID)
                    return true
                }
                guard deliverAuthoritativeTerminalRenderGrid(
                    frame,
                    expectedSurfaceID: surfaceID,
                    source: "scroll_gridless_reconcile"
                ) else {
                    deferredTerminalRenderGridEventsBySurfaceID.removeValue(forKey: surfaceID)
                    MobileDebugLog.anchormux("sync.render_grid_deferred_delivery_failed surface=\(surfaceID)")
                    requestTerminalReplay(surfaceID: surfaceID)
                    return true
                }
                deferredTerminalRenderGridEventsBySurfaceID.removeValue(forKey: surfaceID)
            }
        }
        if let renderRevision {
            acceptTerminalRenderRevision(renderRevision, surfaceID: surfaceID)
        }
        return true
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
        _ = invalidateTerminalScrollForRecovery(surfaceID: surfaceID)
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
            failOpenTerminalReplayBarrier(
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
}
