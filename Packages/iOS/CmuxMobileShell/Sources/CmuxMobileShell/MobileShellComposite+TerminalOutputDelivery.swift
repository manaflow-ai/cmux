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

    func resolveTerminalReplayFailureBarrier(surfaceID: String, token: UUID?) {
        let coldAttachBarrier = token.map {
            terminalColdAttachReplayBarrierTokensBySurfaceID[surfaceID] == $0
        } ?? false
        let missingBaselineBarrier = token.map {
            terminalRenderGridBaselineReplayBarrierTokensBySurfaceID[surfaceID] == $0
        } ?? false
        guard coldAttachBarrier || missingBaselineBarrier else {
            preserveTerminalReplayBarrierIfCurrent(surfaceID: surfaceID, token: token, reason: "failed")
            return
        }
        if clearTerminalReplayBarrierIfCurrent(surfaceID: surfaceID, token: token, reason: "cold_attach_failed") {
            if deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == nil {
                terminalRenderGridBaselineReplayRequestCountsBySurfaceID[surfaceID] = Self.maxTerminalReplayFailureRetries
            }
        }
    }

    func requestTerminalReplayForMissingRenderGridBaseline(surfaceID: String) {
        let requestCount = terminalRenderGridBaselineReplayRequestCountsBySurfaceID[surfaceID] ?? 0
        guard terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil,
              !terminalReplaySurfaceIDsInFlight.contains(surfaceID),
              requestCount < Self.maxTerminalReplayFailureRetries else {
            return
        }
        let replayBarrierToken = beginTerminalReplayBarrier(surfaceID: surfaceID)
        terminalRenderGridBaselineReplayRequestCountsBySurfaceID[surfaceID] = requestCount + 1
        terminalRenderGridBaselineReplayBarrierTokensBySurfaceID[surfaceID] = replayBarrierToken
        requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: replayBarrierToken)
    }

    /// An authoritative replay was accepted: its state supersedes the
    /// pre-barrier floor even when the host's sequence counter restarted lower
    /// (surface recreate), so live frames from the new epoch flow afterwards.
    /// Only replay acceptance may re-base BELOW the floor; live deliveries
    /// release the floor solely by catching up to it (see
    /// ``markTerminalBytesDelivered(surfaceID:endSeq:)``).
    func rebaseTerminalReplayStaleFloor(surfaceID: String) {
        terminalPreBarrierDeliveredEndSeqBySurfaceID.removeValue(forKey: surfaceID)
    }

    /// Move the delivered high-water mark into the pre-barrier stale floor
    /// before a barrier clears it, so buffered pre-barrier frames stay
    /// rejected while the fresh authoritative replay is in flight.
    func stashTerminalPreBarrierDeliveredEndSeq(surfaceID: String) {
        guard let deliveredSeq = deliveredTerminalByteEndSeqBySurfaceID[surfaceID] else { return }
        let stashedSeq = terminalPreBarrierDeliveredEndSeqBySurfaceID[surfaceID] ?? 0
        terminalPreBarrierDeliveredEndSeqBySurfaceID[surfaceID] = max(stashedSeq, deliveredSeq)
    }

    func markTerminalBytesDelivered(surfaceID: String, endSeq: UInt64) {
        let current = deliveredTerminalByteEndSeqBySurfaceID[surfaceID] ?? 0
        deliveredTerminalByteEndSeqBySurfaceID[surfaceID] = max(current, endSeq)
        // A live delivery releases the pre-barrier floor only once the
        // delivered sequence catches up to it; a stale buffered chunk below
        // the floor must not wipe the one guard that keeps other pre-barrier
        // frames from establishing an outdated baseline.
        if let floorSeq = terminalPreBarrierDeliveredEndSeqBySurfaceID[surfaceID],
           (deliveredTerminalByteEndSeqBySurfaceID[surfaceID] ?? 0) >= floorSeq {
            terminalPreBarrierDeliveredEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        }
        let clearBaselineReplayCount = terminalOutputTransport != .hybrid
            || terminalActiveScreenBySurfaceID[surfaceID] != .alternate
            || terminalAlternateRenderGridBaselineSurfaceIDs.contains(surfaceID)
        if clearBaselineReplayCount {
            terminalRenderGridBaselineReplayRequestCountsBySurfaceID.removeValue(forKey: surfaceID)
        }
        if let pendingSeq = pendingTerminalByteEndSeqBySurfaceID[surfaceID],
           endSeq >= pendingSeq {
            pendingTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
            MobileDebugLog.anchormux("sync.input_seq_caught_up surface=\(surfaceID) seq=\(endSeq)")
        }
    }

    func recordTerminalRenderGridDelivery(_ renderGrid: MobileTerminalRenderGridFrame) {
        terminalActiveScreenBySurfaceID[renderGrid.surfaceID] = renderGrid.activeScreen
        if renderGrid.activeScreen == .alternate, renderGrid.full {
            terminalAlternateRenderGridBaselineSurfaceIDs.insert(renderGrid.surfaceID)
        } else if renderGrid.activeScreen == .primary {
            terminalAlternateRenderGridBaselineSurfaceIDs.remove(renderGrid.surfaceID)
        }
    }

    private func renderGridEventDeliveryDecision(
        _ renderGrid: MobileTerminalRenderGridFrame,
        previous: MobileTerminalRenderGridFrame.Screen?
    ) -> (requestReplay: Bool, updateTrackedScreen: Bool, deliverViewportPolicy: Bool)? {
        guard terminalOutputTransport == .hybrid,
              renderGrid.activeScreen == .primary else {
            return nil
        }
        guard previous == .alternate else {
            return (requestReplay: false, updateTrackedScreen: true, deliverViewportPolicy: true)
        }
        guard !renderGrid.full else { return nil }
        return (requestReplay: true, updateTrackedScreen: false, deliverViewportPolicy: false)
    }

    func deliverAuthoritativeTerminalRenderGrid(
        _ renderGrid: MobileTerminalRenderGridFrame,
        expectedSurfaceID: String? = nil,
        source: String
    ) {
        guard expectedSurfaceID == nil || renderGrid.surfaceID == expectedSurfaceID,
              hasTerminalOutputSink(surfaceID: renderGrid.surfaceID) else {
            return
        }
        // The stale floor is the delivered high-water mark, surviving a replay
        // barrier via the pre-barrier stash: a buffered frame from before the
        // barrier must not paint (and must not establish an outdated baseline)
        // while the fresh authoritative replay is pending.
        let staleFloorSeq = max(
            deliveredTerminalByteEndSeqBySurfaceID[renderGrid.surfaceID] ?? 0,
            terminalPreBarrierDeliveredEndSeqBySurfaceID[renderGrid.surfaceID] ?? 0
        )
        if staleFloorSeq > renderGrid.stateSeq {
            MobileDebugLog.anchormux(
                "sync.render_grid_stale source=\(source) surface=\(renderGrid.surfaceID) delivered=\(staleFloorSeq) frame=\(renderGrid.stateSeq)"
            )
            return
        }
        let hasDeliveredSeq = deliveredTerminalByteEndSeqBySurfaceID[renderGrid.surfaceID] != nil
        let previousScreen = terminalActiveScreenBySurfaceID[renderGrid.surfaceID]
        let isRenderGridScreenTransition = previousScreen.map { $0 != renderGrid.activeScreen } ?? false
        let establishesRenderGridBaseline = renderGrid.full
            || (
                renderGrid.activeScreen == .primary
                    && previousScreen != .alternate
                    && renderGrid.isReplaceableViewportPatchForMobileDelivery
            )
        let needsRenderGridBaseline = (
                terminalOutputTransport == .renderGrid
                    && !establishesRenderGridBaseline
                    && (!hasDeliveredSeq || isRenderGridScreenTransition)
            )
            || (
                terminalOutputTransport == .hybrid
                    && renderGrid.activeScreen == .alternate
                    && !terminalAlternateRenderGridBaselineSurfaceIDs.contains(renderGrid.surfaceID)
            )
        if source == "event", needsRenderGridBaseline, !establishesRenderGridBaseline {
            if renderGrid.activeScreen == .alternate {
                terminalActiveScreenBySurfaceID[renderGrid.surfaceID] = .alternate
                terminalAlternateRenderGridBaselineSurfaceIDs.remove(renderGrid.surfaceID)
                deliverTerminalViewportPolicy(renderGrid.mobileViewportPolicy, surfaceID: renderGrid.surfaceID)
            }
            MobileDebugLog.anchormux("sync.render_grid_waiting_for_baseline source=\(source) surface=\(renderGrid.surfaceID) seq=\(renderGrid.stateSeq)")
            if terminalReplayBarrierTokensBySurfaceID[renderGrid.surfaceID] != nil {
                _ = deliverTerminalRenderGrid(renderGrid, surfaceID: renderGrid.surfaceID)
            } else {
                requestTerminalReplayForMissingRenderGridBaseline(surfaceID: renderGrid.surfaceID)
            }
            return
        }
        if source == "event",
           let deliveryDecision = renderGridEventDeliveryDecision(renderGrid, previous: previousScreen) {
            if deliveryDecision.updateTrackedScreen {
                terminalActiveScreenBySurfaceID[renderGrid.surfaceID] = renderGrid.activeScreen
                if renderGrid.activeScreen == .primary {
                    terminalAlternateRenderGridBaselineSurfaceIDs.remove(renderGrid.surfaceID)
                }
            }
            if deliveryDecision.deliverViewportPolicy {
                deliverTerminalViewportPolicy(renderGrid.mobileViewportPolicy, surfaceID: renderGrid.surfaceID)
            }
            MobileDebugLog.anchormux(
                "sync.render_grid_advisory source=\(source) surface=\(renderGrid.surfaceID) screen=\(renderGrid.activeScreen.rawValue) seq=\(renderGrid.stateSeq) requestReplay=\(deliveryDecision.requestReplay) updateTrackedScreen=\(deliveryDecision.updateTrackedScreen) deliverViewportPolicy=\(deliveryDecision.deliverViewportPolicy)"
            )
            if deliveryDecision.requestReplay {
                requestTerminalReplay(surfaceID: renderGrid.surfaceID)
            }
            return
        }
        let activeReplayBarrierToken = terminalReplayBarrierTokensBySurfaceID[renderGrid.surfaceID]
        let bypassLiveBaselineBarrier = source == "event"
            && establishesRenderGridBaseline
            && activeReplayBarrierToken != nil
            && (
                terminalColdAttachReplayBarrierTokensBySurfaceID[renderGrid.surfaceID] == activeReplayBarrierToken
                    || terminalRenderGridBaselineReplayBarrierTokensBySurfaceID[renderGrid.surfaceID] == activeReplayBarrierToken
            )
        if bypassLiveBaselineBarrier {
            terminalOutputQueuesBySurfaceID[renderGrid.surfaceID] = TerminalOutputDeliveryQueue()
            terminalOutputStreamTokensBySurfaceID[renderGrid.surfaceID] = UUID()
            terminalReplayBarrierAckStreamTokensBySurfaceID.removeValue(forKey: renderGrid.surfaceID)
            terminalReplayBarrierAckCoveredDroppedOutputCountsBySurfaceID.removeValue(forKey: renderGrid.surfaceID)
        }
        guard deliverTerminalRenderGrid(
            renderGrid,
            surfaceID: renderGrid.surfaceID,
            bypassReplayBarrier: bypassLiveBaselineBarrier
        ) else { return }
        if bypassLiveBaselineBarrier,
           terminalReplayBarrierAckStreamTokensBySurfaceID[renderGrid.surfaceID] != nil {
            cancelTerminalReplayInFlight(surfaceID: renderGrid.surfaceID)
            terminalReplayBarrierAckCoveredDroppedOutputCountsBySurfaceID[renderGrid.surfaceID] =
                terminalReplayBarrierDroppedOutputCountsBySurfaceID[renderGrid.surfaceID] ?? 0
        }
        recordTerminalRenderGridDelivery(renderGrid)
        markTerminalBytesDelivered(surfaceID: renderGrid.surfaceID, endSeq: renderGrid.stateSeq)
    }

    /// Whether a surface currently has an attached output stream consumer.
    func hasTerminalOutputSink(surfaceID: String) -> Bool {
        terminalByteContinuationsBySurfaceID[surfaceID] != nil
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
            let replayBarrierToken = terminalReplayBarrierTokensBySurfaceID[surfaceID]
            let coldAttachReplayBarrier = replayBarrierToken.map {
                terminalColdAttachReplayBarrierTokensBySurfaceID[surfaceID] == $0
            } ?? false
            let missingBaselineReplayBarrier = replayBarrierToken.map {
                terminalRenderGridBaselineReplayBarrierTokensBySurfaceID[surfaceID] == $0
            } ?? false
            let coveredDroppedOutputCount =
                terminalReplayBarrierAckCoveredDroppedOutputCountsBySurfaceID.removeValue(forKey: surfaceID)
            let currentDroppedOutputCount = terminalReplayBarrierDroppedOutputCountsBySurfaceID[surfaceID] ?? 0
            let needsFollowUpReplay = coveredDroppedOutputCount.map {
                currentDroppedOutputCount > $0
            } ?? true
            terminalReplayBarrierAckStreamTokensBySurfaceID.removeValue(forKey: surfaceID)
            terminalReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
            terminalColdAttachReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
            terminalRenderGridBaselineReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
            MobileDebugLog.anchormux("terminal.output.replay_barrier_cleared surface=\(surfaceID)")
            let droppedOutputDuringBarrier = terminalReplayBarrierDroppedOutputSurfaceIDs.remove(surfaceID) != nil
            terminalReplayBarrierDroppedOutputCountsBySurfaceID.removeValue(forKey: surfaceID)
            if droppedOutputDuringBarrier,
               needsFollowUpReplay,
               claimTerminalReplayBarrierFollowUp(surfaceID: surfaceID) {
                let baselineReplayRequestCount = missingBaselineReplayBarrier
                    ? terminalRenderGridBaselineReplayRequestCountsBySurfaceID[surfaceID]
                    : nil
                let replayBarrierToken = beginTerminalReplayBarrier(
                    surfaceID: surfaceID,
                    preservingFollowUpCount: true
                )
                if coldAttachReplayBarrier {
                    terminalColdAttachReplayBarrierTokensBySurfaceID[surfaceID] = replayBarrierToken
                }
                if missingBaselineReplayBarrier {
                    if let baselineReplayRequestCount {
                        terminalRenderGridBaselineReplayRequestCountsBySurfaceID[surfaceID] = baselineReplayRequestCount
                    }
                    terminalRenderGridBaselineReplayBarrierTokensBySurfaceID[surfaceID] = replayBarrierToken
                }
                MobileDebugLog.anchormux("terminal.output.replay_followup surface=\(surfaceID)")
                requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: replayBarrierToken)
                return
            }
            // Fully resolved: if the acked delivery carried no sequence (a
            // seq-less raw tail), the pre-barrier floor is still the truthful
            // delivered state — restore it so the floor never outlives its
            // barrier.
            if deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == nil,
               let floorSeq = terminalPreBarrierDeliveredEndSeqBySurfaceID[surfaceID] {
                deliveredTerminalByteEndSeqBySurfaceID[surfaceID] = floorSeq
            }
            terminalPreBarrierDeliveredEndSeqBySurfaceID.removeValue(forKey: surfaceID)
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
        stashTerminalPreBarrierDeliveredEndSeq(surfaceID: surfaceID)
        deliveredTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        terminalAlternateRenderGridBaselineSurfaceIDs.remove(surfaceID)
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
