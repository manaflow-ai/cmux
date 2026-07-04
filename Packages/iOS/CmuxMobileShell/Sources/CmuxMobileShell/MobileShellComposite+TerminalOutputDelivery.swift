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
        // A producer grid larger than this phone's reported viewport can never
        // replay faithfully (issue #7202): rows beyond the local grid clamp
        // onto the bottom row and over-wide rows wrap, splicing adjacent rows.
        // Hold the surface's output and drive the Mac back to a capped grid
        // instead of painting the divergence. The grid dimensions are a valid
        // divergence signal even on a stale frame or hybrid advisory event.
        guard renderGridFrameFitsReportedViewport(renderGrid, surfaceID: renderGrid.surfaceID) else {
            holdTerminalOutputForOversizedGrid(
                columns: renderGrid.columns,
                rows: renderGrid.rows,
                surfaceID: renderGrid.surfaceID,
                source: source
            )
            return
        }
        noteFittingRenderGridFrame(surfaceID: renderGrid.surfaceID)
        // The stale floor is the delivered high-water mark, surviving a replay
        // barrier via the pre-barrier stash: a buffered frame from before the
        // barrier must not paint (and must not establish an outdated baseline)
        // while the fresh authoritative replay is pending. Against the STASH
        // the rejection includes EQUAL sequences — the surface already shows
        // that content and render grids re-emit at unchanged byte sequences,
        // so a same-seq buffered full frame must not cancel the pending
        // replay. Against the live delivered mark only strictly-older frames
        // are stale, so steady-state same-seq re-emits (resize repaints)
        // still deliver.
        let deliveredSeqValue = deliveredTerminalByteEndSeqBySurfaceID[renderGrid.surfaceID] ?? 0
        let preBarrierFloorSeq = terminalPreBarrierDeliveredEndSeqBySurfaceID[renderGrid.surfaceID]
        if deliveredSeqValue > renderGrid.stateSeq
            || preBarrierFloorSeq.map({ $0 >= renderGrid.stateSeq }) ?? false {
            MobileDebugLog.anchormux(
                "sync.render_grid_stale source=\(source) surface=\(renderGrid.surfaceID) delivered=\(max(deliveredSeqValue, preBarrierFloorSeq ?? 0)) frame=\(renderGrid.stateSeq)"
            )
            return
        }
        // Frames behind an outstanding typing ACK (or partial frames while a
        // dropped-frame replay is pending) must not paint an older cursor
        // frame or establish a baseline from pre-input content.
        guard !shouldDropRenderGridBehindPendingInput(renderGrid, source: source) else { return }
        let hasDeliveredSeq = deliveredTerminalByteEndSeqBySurfaceID[renderGrid.surfaceID] != nil
        let previousScreen = terminalActiveScreenBySurfaceID[renderGrid.surfaceID]
        // The alternate baseline flag is maintained by DELIVERED frames only,
        // so gating on it (in both screen directions) cannot be fooled by the
        // speculative tracked-screen write below: a delta VT patch cannot
        // switch screens, so it may only paint the screen the local surface
        // actually shows.
        let hasAlternateBaseline = terminalAlternateRenderGridBaselineSurfaceIDs.contains(renderGrid.surfaceID)
        let establishesRenderGridBaseline = renderGrid.full
            || (
                renderGrid.activeScreen == .primary
                    && !hasAlternateBaseline
                    && renderGrid.isReplaceableViewportPatchForMobileDelivery
            )
        let needsRenderGridBaseline = (
                terminalOutputTransport == .renderGrid
                    && !establishesRenderGridBaseline
                    && (
                        !hasDeliveredSeq
                            || (renderGrid.activeScreen == .alternate) != hasAlternateBaseline
                    )
            )
            || (
                terminalOutputTransport == .hybrid
                    && renderGrid.activeScreen == .alternate
                    && !hasAlternateBaseline
            )
        if source == "event", needsRenderGridBaseline, !establishesRenderGridBaseline {
            if renderGrid.activeScreen == .alternate {
                terminalActiveScreenBySurfaceID[renderGrid.surfaceID] = .alternate
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
            if renderGrid.full,
               terminalReplayBarrierTokensBySurfaceID[renderGrid.surfaceID] == nil {
                markTerminalFullReplacementObserved(
                    surfaceID: renderGrid.surfaceID,
                    seq: renderGrid.stateSeq
                )
            }
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
        markTerminalBytesDelivered(
            surfaceID: renderGrid.surfaceID,
            endSeq: renderGrid.stateSeq,
            fullReplacement: renderGrid.full
        )
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
        // Never paint a frame authored for a grid larger than this phone's
        // reported viewport — it splices adjacent rows (issue #7202). A replay
        // response still oversized means the Mac has not re-applied the cap
        // yet: consume a bounded retry so the barrier keeps polling for the
        // converged grid; other callers restart the paced recovery.
        guard renderGridFrameFitsReportedViewport(frame, surfaceID: surfaceID) else {
            if bypassReplayBarrier, terminalReplayBarrierTokensBySurfaceID[surfaceID] != nil {
                // Withholding the replay response is itself dropped output;
                // the hold records it so the caller's not_delivered cleanup
                // keeps the barrier alive (preserveDroppedOutput), and — for a
                // barrier that did not originate from an oversized live frame
                // (e.g. terminalOutputDidReset on an idle surface) — starts
                // the recovery bookkeeping, most importantly the paced
                // viewport re-assert that drives the Mac to re-cap.
                holdTerminalOutputForOversizedGrid(
                    columns: frame.columns,
                    rows: frame.rows,
                    surfaceID: surfaceID,
                    source: "replay_response"
                )
                retryTerminalReplayForOversizedGrid(surfaceID: surfaceID)
            } else {
                holdTerminalOutputForOversizedGrid(
                    columns: frame.columns,
                    rows: frame.rows,
                    surfaceID: surfaceID,
                    source: "delivery"
                )
            }
            return false
        }
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
            // Fully resolved: a seq-less raw tail leaves no delivered sequence,
            // so the floor restore is the truthful baseline hand-back.
            restoreTerminalPreBarrierBaselineIfNeeded(surfaceID: surfaceID)
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
        let replayBarrierToken = beginTerminalReplayBarrier(surfaceID: surfaceID)
        rebaseTerminalReplayStaleFloor(surfaceID: surfaceID)
        terminalAlternateRenderGridBaselineSurfaceIDs.remove(surfaceID)
        MobileDebugLog.anchormux("terminal.output.replay_requested surface=\(surfaceID)")
        requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: replayBarrierToken)
    }

}
