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
            terminalSyncDiagnostics.renderGridDropped(
                surface: Self.diagnosticSurfaceHandle(renderGrid.surfaceID),
                gate: .baselineWait,
                droppedFrames: 1,
                replayRetryCount: terminalReplayFailureRetryCountsBySurfaceID[renderGrid.surfaceID] ?? 0,
                barrierFollowUpCount: terminalReplayBarrierFollowUpCountsBySurfaceID[renderGrid.surfaceID] ?? 0,
                transport: terminalOutputTransport.debugName
            )
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
        if establishesRenderGridBaseline {
            terminalSyncDiagnostics.gateResolved(
                surface: Self.diagnosticSurfaceHandle(renderGrid.surfaceID),
                gate: .baselineWait,
                how: .catchupFrame,
                transport: terminalOutputTransport.debugName
            )
        }
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

    /// Whether delivering this frame establishes the render-grid baseline the
    /// baseline-wait gate is holding out for. Mirrors the authoritative
    /// delivery path's inline computation; the replay success path uses it to
    /// resolve the `.baselineWait` stall gate. Read BEFORE
    /// ``recordTerminalRenderGridDelivery(_:)`` mutates the alternate-baseline set.
    func renderGridEstablishesBaseline(_ renderGrid: MobileTerminalRenderGridFrame) -> Bool {
        renderGrid.full
            || (
                renderGrid.activeScreen == .primary
                    && !terminalAlternateRenderGridBaselineSurfaceIDs.contains(renderGrid.surfaceID)
                    && renderGrid.isReplaceableViewportPatchForMobileDelivery
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
            terminalSyncDiagnostics.renderGridDropped(
                surface: Self.diagnosticSurfaceHandle(surfaceID),
                gate: .replayBarrier,
                droppedFrames: droppedOutputCount,
                replayRetryCount: terminalReplayFailureRetryCountsBySurfaceID[surfaceID] ?? 0,
                barrierFollowUpCount: terminalReplayBarrierFollowUpCountsBySurfaceID[surfaceID] ?? 0,
                transport: terminalOutputTransport.debugName
            )
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
            terminalSyncDiagnostics.barrierCleared(
                surface: Self.diagnosticSurfaceHandle(surfaceID),
                reason: .replayAck,
                transport: terminalOutputTransport.debugName
            )
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
                    preservingFollowUpCount: true,
                    trigger: .barrier
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

}
