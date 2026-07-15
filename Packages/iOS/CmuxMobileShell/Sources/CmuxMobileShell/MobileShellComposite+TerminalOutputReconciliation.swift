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

    func enqueueTerminalLocalScrollMutation(
        surfaceID: String,
        runs: [MobileTerminalScrollRun]
    ) -> TerminalSurfaceMutationReceipt {
        let receipt = TerminalSurfaceMutationReceipt()
        let delivery = TerminalOutputDelivery(localScroll: runs, receipt: receipt)
        if terminalReplayBarrierTokensBySurfaceID[surfaceID] != nil {
            return enqueueTerminalBarrierInteraction(delivery, surfaceID: surfaceID)
        }
        guard let continuation = terminalByteContinuationsBySurfaceID[surfaceID],
              let streamToken = terminalOutputStreamTokensBySurfaceID[surfaceID] else {
            receipt.resolve(false)
            return receipt
        }
        var queue = terminalOutputQueuesBySurfaceID[surfaceID] ?? TerminalOutputDeliveryQueue()
        let enqueueResult = queue.enqueueOptimisticScroll(delivery)
        let superseded = queue.takeScrollReconciliationSupersessions()
        terminalOutputQueuesBySurfaceID[surfaceID] = queue
        acknowledgeSupersededTerminalScrollReconciliations(
            superseded,
            surfaceID: surfaceID
        )
        if let immediate = enqueueResult.immediate {
            continuation.yield(MobileTerminalOutputChunk(
                mutation: immediate.mutation,
                streamToken: streamToken,
                deliveryID: immediate.deliveryID
            ))
        }
        return enqueueResult.receipt
    }

    func enqueueTerminalScrollToBottomMutation(surfaceID: String) -> TerminalSurfaceMutationReceipt {
        let receipt = TerminalSurfaceMutationReceipt()
        let delivery = TerminalOutputDelivery(scrollToBottomReceipt: receipt)
        if terminalReplayBarrierTokensBySurfaceID[surfaceID] != nil {
            return enqueueTerminalBarrierInteraction(delivery, surfaceID: surfaceID)
        }
        let accepted = deliverTerminalOutput(
            delivery,
            surfaceID: surfaceID
        )
        if !accepted { receipt.resolve(false) }
        return receipt
    }

    func enqueueTerminalMutationBarrier(surfaceID: String) -> TerminalSurfaceMutationReceipt {
        let receipt = TerminalSurfaceMutationReceipt()
        let delivery = TerminalOutputDelivery(barrierReceipt: receipt)
        if terminalReplayBarrierTokensBySurfaceID[surfaceID] != nil {
            return enqueueTerminalBarrierInteraction(delivery, surfaceID: surfaceID)
        }
        let accepted = deliverTerminalOutput(
            delivery,
            surfaceID: surfaceID
        )
        if !accepted { receipt.resolve(false) }
        return receipt
    }

    func invalidateQueuedTerminalScrollReconciliations(surfaceID: String) {
        guard let continuation = terminalByteContinuationsBySurfaceID[surfaceID],
              let streamToken = terminalOutputStreamTokensBySurfaceID[surfaceID],
              var queue = terminalOutputQueuesBySurfaceID[surfaceID] else {
            return
        }
        let result = queue.invalidateScrollReconciliations()
        let superseded = queue.takeScrollReconciliationSupersessions()
        terminalOutputQueuesBySurfaceID[surfaceID] = queue
        acknowledgeSupersededTerminalScrollReconciliations(
            superseded,
            surfaceID: surfaceID
        )
        switch result {
        case .advanced(let immediate):
            if let immediate {
                continuation.yield(MobileTerminalOutputChunk(
                    mutation: immediate.mutation,
                    streamToken: streamToken,
                    deliveryID: immediate.deliveryID
                ))
            }
        case .claimed:
            let replayBarrierToken = beginTerminalReplayBarrier(surfaceID: surfaceID)
            MobileDebugLog.anchormux(
                "terminal.output.input_claimed_reconciliation surface=\(surfaceID)"
            )
            requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: replayBarrierToken)
        }
    }

    func resetTerminalMutationQueue(
        surfaceID: String,
        remove: Bool = false,
        preservingBarrierInteractions: Bool = false
    ) {
        if var queue = terminalOutputQueuesBySurfaceID[surfaceID] {
            if preservingBarrierInteractions {
                queue.resetForReplayBarrier(
                    claimedStreamToken: terminalOutputStreamTokensBySurfaceID[surfaceID]
                )
            } else {
                queue.reset()
            }
            terminalOutputQueuesBySurfaceID[surfaceID] = queue
        }
        if remove {
            terminalOutputQueuesBySurfaceID.removeValue(forKey: surfaceID)
        } else if terminalOutputQueuesBySurfaceID[surfaceID] == nil {
            terminalOutputQueuesBySurfaceID[surfaceID] = TerminalOutputDeliveryQueue()
        }
    }

    private func enqueueTerminalBarrierInteraction(
        _ delivery: TerminalOutputDelivery,
        surfaceID: String
    ) -> TerminalSurfaceMutationReceipt {
        guard terminalByteContinuationsBySurfaceID[surfaceID] != nil,
              var queue = terminalOutputQueuesBySurfaceID[surfaceID] else {
            delivery.resolveReceipt(false)
            return delivery.primaryReceipt!
        }
        let receipt = queue.enqueueBarrierInteraction(delivery)
        terminalOutputQueuesBySurfaceID[surfaceID] = queue
        return receipt
    }

    func releaseTerminalReplayBarrierInteractions(surfaceID: String) {
        guard terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil,
              let continuation = terminalByteContinuationsBySurfaceID[surfaceID],
              let streamToken = terminalOutputStreamTokensBySurfaceID[surfaceID],
              var queue = terminalOutputQueuesBySurfaceID[surfaceID] else { return }
        let immediate = queue.releaseBarrierInteractions()
        let superseded = queue.takeScrollReconciliationSupersessions()
        terminalOutputQueuesBySurfaceID[surfaceID] = queue
        acknowledgeSupersededTerminalScrollReconciliations(
            superseded,
            surfaceID: surfaceID
        )
        if let immediate {
            continuation.yield(MobileTerminalOutputChunk(
                mutation: immediate.mutation,
                streamToken: streamToken,
                deliveryID: immediate.deliveryID
            ))
        }
    }

    func acknowledgeSupersededTerminalScrollReconciliations(
        _ supersessions: [TerminalScrollReconciliationSupersession],
        surfaceID: String
    ) {
        guard let session = terminalScrollSessionsBySurfaceID[surfaceID] else { return }
        for supersession in supersessions {
            session.authoritativeReconciliationWasSuperseded(supersession)
        }
    }

    func observeTerminalRenderRevision(_ revision: UInt64, surfaceID: String) {
        observedTerminalRenderRevisionsBySurfaceID[surfaceID] = max(
            observedTerminalRenderRevisionsBySurfaceID[surfaceID] ?? 0,
            revision
        )
    }

    func acceptTerminalRenderRevision(_ revision: UInt64, surfaceID: String) {
        observeTerminalRenderRevision(revision, surfaceID: surfaceID)
        acceptedTerminalRenderRevisionsBySurfaceID[surfaceID] = max(
            acceptedTerminalRenderRevisionsBySurfaceID[surfaceID] ?? 0,
            revision
        )
        appliedTerminalRenderRevisionsBySurfaceID[surfaceID] = revision
        if let allowedRevision = equalRevisionTerminalRecoveryReplaysBySurfaceID[surfaceID],
           revision >= allowedRevision {
            equalRevisionTerminalRecoveryReplaysBySurfaceID.removeValue(forKey: surfaceID)
        }
    }

    func acceptGridlessTerminalRenderRevision(_ revision: UInt64, surfaceID: String) {
        observeTerminalRenderRevision(revision, surfaceID: surfaceID)
        acceptedTerminalRenderRevisionsBySurfaceID[surfaceID] = max(
            acceptedTerminalRenderRevisionsBySurfaceID[surfaceID] ?? 0,
            revision
        )
        // The acknowledgement advances ordering without describing pixels for
        // this revision, so no later delta can reuse the old applied baseline.
        appliedTerminalRenderRevisionsBySurfaceID.removeValue(forKey: surfaceID)
    }

    func deferTerminalRenderGridEvent(
        _ frame: MobileTerminalRenderGridFrame,
        preparedBytes: Data? = nil
    ) {
        guard var deferred = deferredTerminalRenderGridEventsBySurfaceID[frame.surfaceID] else {
            deferredTerminalRenderGridEventsBySurfaceID[frame.surfaceID] = DeferredTerminalRenderGridEvent(
                frame: frame,
                preparedBytes: preparedBytes
            )
            return
        }
        deferred.append(frame, preparedBytes: preparedBytes)
        deferredTerminalRenderGridEventsBySurfaceID[frame.surfaceID] = deferred
    }

    func flushDeferredTerminalRenderGridEvent(
        surfaceID: String,
        followingScrollRuns: [MobileTerminalScrollRun] = []
    ) {
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
            source: "event",
            preparedBytes: deferred.preparedBytes,
            followingScrollRuns: followingScrollRuns
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
                    acceptGridlessTerminalRenderRevision(renderRevision, surfaceID: surfaceID)
                    equalRevisionTerminalRecoveryReplaysBySurfaceID[surfaceID] = renderRevision
                }
                MobileDebugLog.anchormux("sync.render_grid_deferred_replay surface=\(surfaceID)")
                requestTerminalReplay(surfaceID: surfaceID)
                return true
            }
            if let frame = deferred.frame {
                if let renderRevision,
                   frame.renderRevision.map({ $0 < renderRevision }) ?? true {
                    deferredTerminalRenderGridEventsBySurfaceID.removeValue(forKey: surfaceID)
                    acceptGridlessTerminalRenderRevision(renderRevision, surfaceID: surfaceID)
                    equalRevisionTerminalRecoveryReplaysBySurfaceID[surfaceID] = renderRevision
                    MobileDebugLog.anchormux(
                        "sync.render_grid_deferred_behind_ack surface=\(surfaceID) ack=\(renderRevision) deferred=\(frame.renderRevision ?? 0)"
                    )
                    requestTerminalReplay(surfaceID: surfaceID)
                    return true
                }
                guard deliverAuthoritativeTerminalRenderGrid(
                    frame,
                    expectedSurfaceID: surfaceID,
                    source: "scroll_gridless_reconcile",
                    preparedBytes: deferred.preparedBytes
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
            acceptGridlessTerminalRenderRevision(renderRevision, surfaceID: surfaceID)
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
        guard var queue = terminalOutputQueuesBySurfaceID[surfaceID] else { return }
        guard terminalOutputStreamTokensBySurfaceID[surfaceID] == streamToken else {
            let next = queue.completeClaimedReplayInteraction(
                streamToken: streamToken,
                applied: false
            )
            terminalOutputQueuesBySurfaceID[surfaceID] = queue
            if let next,
               let continuation = terminalByteContinuationsBySurfaceID[surfaceID],
               let currentStreamToken = terminalOutputStreamTokensBySurfaceID[surfaceID] {
                continuation.yield(MobileTerminalOutputChunk(
                    mutation: next.mutation,
                    streamToken: currentStreamToken,
                    deliveryID: next.deliveryID
                ))
            }
            return
        }
        appliedTerminalRenderRevisionsBySurfaceID.removeValue(forKey: surfaceID)
        // This callback is the claimed consumer's definitive failure result.
        // Consume it before stream rotation so replay retention cannot wait for
        // a second callback that the renderer will never send.
        _ = queue.completeClaimedInFlight(applied: false)
        terminalOutputQueuesBySurfaceID[surfaceID] = queue
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
        resetTerminalMutationQueue(surfaceID: surfaceID, preservingBarrierInteractions: true)
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
