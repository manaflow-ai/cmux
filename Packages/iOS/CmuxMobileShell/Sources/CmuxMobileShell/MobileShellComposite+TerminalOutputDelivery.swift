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
        // The toolbar observes this dictionary via `isAlternateScreen`; same-value
        // writes would re-fire observers for every delivered render-grid frame.
        if terminalActiveScreenBySurfaceID[renderGrid.surfaceID] != renderGrid.activeScreen {
            terminalActiveScreenBySurfaceID[renderGrid.surfaceID] = renderGrid.activeScreen
        }
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

    @discardableResult
    func deliverAuthoritativeTerminalRenderGrid(
        _ renderGrid: MobileTerminalRenderGridFrame,
        expectedSurfaceID: String? = nil,
        source: String,
        bypassReplayBarrier: Bool = false,
        scrollReconciliation: TerminalScrollReconciliation? = nil
    ) -> Bool {
        guard expectedSurfaceID == nil || renderGrid.surfaceID == expectedSurfaceID,
              hasTerminalOutputSink(surfaceID: renderGrid.surfaceID) else {
            return false
        }
        if source == "event",
           terminalScrollSessionsBySurfaceID[renderGrid.surfaceID]?.shouldDeferLiveRenderGrid == true {
            deferTerminalRenderGridEvent(renderGrid)
            MobileDebugLog.anchormux(
                "sync.render_grid_wait_scroll surface=\(renderGrid.surfaceID) revision=\(renderGrid.renderRevision ?? 0)"
            )
            return false
        }
        if let renderRevision = renderGrid.renderRevision,
           let acceptedRevision = acceptedTerminalRenderRevisionsBySurfaceID[renderGrid.surfaceID],
           renderRevision <= acceptedRevision {
            MobileDebugLog.anchormux(
                "sync.render_grid_stale_revision source=\(source) surface=\(renderGrid.surfaceID) accepted=\(acceptedRevision) frame=\(renderRevision)"
            )
            if let scrollReconciliation {
                terminalScrollSessionsBySurfaceID[renderGrid.surfaceID]?.authoritativeDidApply(
                    interactionEpoch: scrollReconciliation.interactionEpoch,
                    clientRevision: scrollReconciliation.clientRevision
                )
                return true
            }
            return false
        }
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
        let hasRevisionOrderedReplay = source == "replay" && renderGrid.renderRevision != nil
        if !hasRevisionOrderedReplay,
           deliveredSeqValue > renderGrid.stateSeq
            || preBarrierFloorSeq.map({ $0 >= renderGrid.stateSeq }) ?? false {
            MobileDebugLog.anchormux(
                "sync.render_grid_stale source=\(source) surface=\(renderGrid.surfaceID) delivered=\(max(deliveredSeqValue, preBarrierFloorSeq ?? 0)) frame=\(renderGrid.stateSeq)"
            )
            return false
        }
        // Frames behind an outstanding typing ACK (or partial frames while a
        // dropped-frame replay is pending) must not paint an older cursor
        // frame or establish a baseline from pre-input content.
        guard !shouldDropRenderGridBehindPendingInput(renderGrid, source: source) else { return false }
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
                if terminalActiveScreenBySurfaceID[renderGrid.surfaceID] != .alternate {
                    terminalActiveScreenBySurfaceID[renderGrid.surfaceID] = .alternate
                }
                deliverTerminalViewportPolicy(renderGrid.mobileViewportPolicy, surfaceID: renderGrid.surfaceID)
            }
            MobileDebugLog.anchormux("sync.render_grid_waiting_for_baseline source=\(source) surface=\(renderGrid.surfaceID) seq=\(renderGrid.stateSeq)")
            if terminalReplayBarrierTokensBySurfaceID[renderGrid.surfaceID] != nil {
                let delivered = deliverTerminalRenderGrid(renderGrid, surfaceID: renderGrid.surfaceID)
                if delivered, let renderRevision = renderGrid.renderRevision {
                    acceptTerminalRenderRevision(renderRevision, surfaceID: renderGrid.surfaceID)
                }
            } else {
                requestTerminalReplayForMissingRenderGridBaseline(surfaceID: renderGrid.surfaceID)
            }
            return false
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
                if terminalActiveScreenBySurfaceID[renderGrid.surfaceID] != renderGrid.activeScreen {
                    terminalActiveScreenBySurfaceID[renderGrid.surfaceID] = renderGrid.activeScreen
                }
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
            return false
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
        let shouldBypassReplayBarrier = bypassReplayBarrier || bypassLiveBaselineBarrier
        guard deliverTerminalRenderGrid(
            renderGrid,
            surfaceID: renderGrid.surfaceID,
            bypassReplayBarrier: shouldBypassReplayBarrier,
            scrollReconciliation: scrollReconciliation
        ) else { return false }
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
        if let renderRevision = renderGrid.renderRevision {
            acceptTerminalRenderRevision(renderRevision, surfaceID: renderGrid.surfaceID)
        }
        return true
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
        bypassReplayBarrier: Bool = false,
        scrollbackOffsetFromBottomRows: Int? = nil
    ) -> Bool {
        return deliverTerminalOutput(
            TerminalOutputDelivery(
                bytes: bytes,
                replaceable: false,
                viewportPolicy: .natural,
                scrollbackOffsetFromBottomRows: scrollbackOffsetFromBottomRows
            ),
            surfaceID: surfaceID,
            bypassReplayBarrier: bypassReplayBarrier
        )
    }

    @discardableResult
    func deliverTerminalRenderGrid(
        _ frame: MobileTerminalRenderGridFrame,
        surfaceID: String,
        bypassReplayBarrier: Bool = false,
        scrollReconciliation: TerminalScrollReconciliation? = nil
    ) -> Bool {
        return deliverTerminalOutput(
            TerminalOutputDelivery(
                renderGrid: frame,
                replaceable: scrollReconciliation == nil
                    && frame.isReplaceableViewportPatchForMobileDelivery,
                viewportPolicy: frame.mobileViewportPolicy,
                scrollReconciliation: scrollReconciliation
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
            if droppedOutputCount >= Self.maxTerminalReplayBarrierDroppedOutputBeforeFailOpen {
                failOpenTerminalReplayBarrier(
                    surfaceID: surfaceID,
                    token: replayBarrierToken,
                    reason: "dropped_output_cap"
                )
                return deliverTerminalOutput(delivery, surfaceID: surfaceID, bypassReplayBarrier: true)
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
                    deliveryID: immediate.deliveryID,
                    viewportPolicy: immediate.viewportPolicy,
                    scrollbackOffsetFromBottomRows: immediate.scrollbackOffsetFromBottomRows
                )
            )
        }
        return true
    }

    /// Mark the current yielded terminal-output chunk as applied by the iOS surface.
    public func terminalOutputDidProcess(surfaceID: String, streamToken: UUID) {
        guard terminalOutputStreamTokensBySurfaceID[surfaceID] == streamToken,
              var queue = terminalOutputQueuesBySurfaceID[surfaceID] else { return }
        let completedDelivery = queue.currentInFlight
        let next = queue.completeInFlight()
        terminalOutputQueuesBySurfaceID[surfaceID] = queue
        if let reconciliation = completedDelivery?.scrollReconciliation {
            terminalScrollSessionsBySurfaceID[surfaceID]?.authoritativeDidApply(
                interactionEpoch: reconciliation.interactionEpoch,
                clientRevision: reconciliation.clientRevision
            )
        }
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
            let droppedOutputDuringBarrier = terminalReplayBarrierDroppedOutputSurfaceIDs.contains(surfaceID)
            if droppedOutputDuringBarrier, needsFollowUpReplay {
                if claimTerminalReplayBarrierFollowUp(surfaceID: surfaceID) {
                    let baselineReplayRequestCount = missingBaselineReplayBarrier
                        ? terminalRenderGridBaselineReplayRequestCountsBySurfaceID[surfaceID]
                        : nil
                    terminalReplayBarrierAckStreamTokensBySurfaceID.removeValue(forKey: surfaceID)
                    terminalReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
                    terminalColdAttachReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
                    terminalRenderGridBaselineReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
                    MobileDebugLog.anchormux("terminal.output.replay_barrier_cleared surface=\(surfaceID)")
                    terminalReplayBarrierDroppedOutputSurfaceIDs.remove(surfaceID)
                    terminalReplayBarrierDroppedOutputCountsBySurfaceID.removeValue(forKey: surfaceID)
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
                _ = failOpenTerminalReplayBarrier(
                    surfaceID: surfaceID,
                    token: replayBarrierToken,
                    reason: "followup_cap"
                )
            } else {
                terminalReplayBarrierAckStreamTokensBySurfaceID.removeValue(forKey: surfaceID)
                terminalReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
                terminalColdAttachReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
                terminalRenderGridBaselineReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
                MobileDebugLog.anchormux("terminal.output.replay_barrier_cleared surface=\(surfaceID)")
                terminalReplayBarrierDroppedOutputSurfaceIDs.remove(surfaceID)
                terminalReplayBarrierDroppedOutputCountsBySurfaceID.removeValue(forKey: surfaceID)
                // Fully resolved: a seq-less raw tail leaves no delivered sequence,
                // so the floor restore is the truthful baseline hand-back.
                restoreTerminalPreBarrierBaselineIfNeeded(surfaceID: surfaceID)
                terminalReplayBarrierFollowUpCountsBySurfaceID.removeValue(forKey: surfaceID)
            }
        }
        guard let next,
              let continuation = terminalByteContinuationsBySurfaceID[surfaceID],
              terminalOutputStreamTokensBySurfaceID[surfaceID] == streamToken else {
            return
        }
        continuation.yield(MobileTerminalOutputChunk(
            data: next.bytes,
            streamToken: streamToken,
            deliveryID: next.deliveryID,
            viewportPolicy: next.viewportPolicy,
            scrollbackOffsetFromBottomRows: next.scrollbackOffsetFromBottomRows
        ))
    }


    /// Ask the Mac to replay the authoritative terminal state for a surface.
    /// Reached from the render-pipeline reset: the surface was rebuilt blank,
    /// so (like ``terminalOutputDidReset``) no pre-barrier baseline survives.
    public func terminalOutputNeedsReplay(surfaceID: String) {
        guard terminalByteContinuationsBySurfaceID[surfaceID] != nil else { return }
        _ = invalidateTerminalScrollForRecovery(surfaceID: surfaceID)
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
