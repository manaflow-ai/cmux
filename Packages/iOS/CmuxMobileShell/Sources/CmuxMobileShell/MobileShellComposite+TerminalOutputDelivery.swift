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
            recordAppEvent(
                .terminalAlternateScreenChanged,
                correlationID: renderGrid.surfaceID,
                count: renderGrid.activeScreen == .alternate ? 1 : 0
            )
        }
        if renderGrid.activeScreen == .alternate, renderGrid.full {
            terminalAlternateRenderGridBaselineSurfaceIDs.insert(renderGrid.surfaceID)
        } else if renderGrid.activeScreen == .primary {
            terminalAlternateRenderGridBaselineSurfaceIDs.remove(renderGrid.surfaceID)
        }
    }

    /// Record the screen-anchor history that the next live delta must link to.
    func recordTerminalRenderGridHistoryContinuity(
        _ renderGrid: MobileTerminalRenderGridFrame
    ) {
        if renderGrid.anchor == .screen, let historyRows = renderGrid.historyRows {
            terminalRenderGridHistoryContinuityBySurfaceID[renderGrid.surfaceID] = historyRows
        } else {
            terminalRenderGridHistoryContinuityBySurfaceID.removeValue(forKey: renderGrid.surfaceID)
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
            #if DEBUG
            MobileLatencyTrace.stamp(
                "gate",
                "s=\(renderGrid.surfaceID.prefix(8).lowercased()) " +
                    "seq=\(renderGrid.stateSeq) out=drop_stale"
            )
            #endif
            return
        }
        // Theme revisions are ordered independently from terminal byte content.
        // A delayed full frame may be stale for the VT replay while still carrying
        // the newest theme revision, and subsequent deltas intentionally omit it.
        let acceptedNewTheme = recordTerminalTheme(renderGrid)
        if acceptedNewTheme {
            _ = deliverTerminalTheme(renderGrid, surfaceID: renderGrid.surfaceID)
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
            #if DEBUG
            MobileLatencyTrace.stamp(
                "gate",
                "s=\(renderGrid.surfaceID.prefix(8).lowercased()) " +
                    "seq=\(renderGrid.stateSeq) out=drop_stale"
            )
            #endif
            return
        }
        // Frames behind an outstanding typing ACK (or partial frames while a
        // dropped-frame replay is pending) must not paint an older cursor
        // frame or establish a baseline from pre-input content.
        guard !shouldDropRenderGridBehindPendingInput(renderGrid, source: source) else {
            #if DEBUG
            MobileLatencyTrace.stamp(
                "gate",
                "s=\(renderGrid.surfaceID.prefix(8).lowercased()) " +
                    "seq=\(renderGrid.stateSeq) out=drop_pending_input"
            )
            #endif
            return
        }
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
                _ = deliverTerminalRenderGrid(renderGrid, surfaceID: renderGrid.surfaceID)
                #if DEBUG
                MobileLatencyTrace.stamp(
                    "gate",
                    "s=\(renderGrid.surfaceID.prefix(8).lowercased()) " +
                        "seq=\(renderGrid.stateSeq) out=barrier"
                )
                #endif
            } else {
                requestTerminalReplayForMissingRenderGridBaseline(surfaceID: renderGrid.surfaceID)
                #if DEBUG
                MobileLatencyTrace.stamp(
                    "gate",
                    "s=\(renderGrid.surfaceID.prefix(8).lowercased()) " +
                        "seq=\(renderGrid.stateSeq) out=replay_req"
                )
                #endif
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
            #if DEBUG
            MobileLatencyTrace.stamp(
                "gate",
                "s=\(renderGrid.surfaceID.prefix(8).lowercased()) " +
                    "seq=\(renderGrid.stateSeq) " +
                    "out=\(deliveryDecision.requestReplay ? "replay_req" : "delivered")"
            )
            #endif
            return
        }
        // Chain-link screen-anchored deltas to what this device actually
        // delivered: each delta names the history count of the producer frame
        // it was diffed against. If that is not the last delivered frame, a
        // frame was missed and dirty-row patching can no longer realign the
        // grid or local scrollback; request a full replay instead of painting.
        // The producer sets the base on every screen delta, so a missing base
        // is malformed and fails closed the same way. Skipped while a replay
        // barrier is active - the barrier already drops deltas and resolves
        // with an authoritative replay.
        if !renderGrid.full,
           renderGrid.anchor == .screen,
           renderGrid.activeScreen == .primary,
           terminalReplayBarrierTokensBySurfaceID[renderGrid.surfaceID] == nil {
            let deltaBase = renderGrid.deltaBaseHistoryRows
            let delivered = terminalRenderGridHistoryContinuityBySurfaceID[renderGrid.surfaceID]
            if deltaBase == nil || deltaBase != delivered {
                MobileDebugLog.anchormux(
                    "sync.render_grid_history_chain_break surface=\(renderGrid.surfaceID) " +
                        "base=\(deltaBase.map(String.init) ?? "nil") " +
                        "delivered=\(delivered.map(String.init) ?? "nil") seq=\(renderGrid.stateSeq)"
                )
                terminalOutputNeedsReplay(surfaceID: renderGrid.surfaceID)
                #if DEBUG
                MobileLatencyTrace.stamp(
                    "gate",
                    "s=\(renderGrid.surfaceID.prefix(8).lowercased()) " +
                        "seq=\(renderGrid.stateSeq) out=replay_req"
                )
                #endif
                return
            }
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
            if acceptedNewTheme {
                _ = deliverTerminalTheme(
                    renderGrid,
                    surfaceID: renderGrid.surfaceID,
                    bypassReplayBarrier: true
                )
            }
        }
        guard deliverTerminalRenderGrid(
            renderGrid,
            surfaceID: renderGrid.surfaceID,
            bypassReplayBarrier: bypassLiveBaselineBarrier
        ) else {
            #if DEBUG
            MobileLatencyTrace.stamp(
                "gate",
                "s=\(renderGrid.surfaceID.prefix(8).lowercased()) " +
                    "seq=\(renderGrid.stateSeq) out=barrier"
            )
            #endif
            return
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
        recordTerminalRenderGridHistoryContinuity(renderGrid)
        if renderGrid.full, renderGrid.scrollbackRows > 0 {
            terminalMirrorHydrationNeededSurfaceIDs.remove(renderGrid.surfaceID)
        }
        #if DEBUG
        MobileLatencyTrace.stamp(
            "gate",
            "s=\(renderGrid.surfaceID.prefix(8).lowercased()) " +
                "seq=\(renderGrid.stateSeq) out=delivered"
        )
        #endif
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
        endSequence: UInt64? = nil,
        viewportPolicy: MobileTerminalOutputViewportPolicy? = .natural,
        replayVerificationPolicy: TerminalOutputDelivery.ReplayVerificationPolicy = .automatic,
        bypassReplayBarrier: Bool = false
    ) -> Bool {
        return deliverTerminalOutput(
            TerminalOutputDelivery(
                bytes: bytes,
                replaceable: false,
                viewportPolicy: viewportPolicy,
                endSequence: endSequence,
                replayVerificationPolicy: replayVerificationPolicy
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
        let hasCurrentThemeRevision = hasCurrentTerminalThemeRevision(frame)
        recordTerminalTheme(frame)
        let deliveryFrame: MobileTerminalRenderGridFrame
        if hasCurrentThemeRevision {
            deliveryFrame = frame
        } else {
            MobileDebugLog.anchormux(
                "sync.render_grid_stale_theme surface=\(frame.surfaceID) revision=\(frame.terminalThemeRevision ?? 0)"
            )
            deliveryFrame = frame.replacingThemeColors(
                with: terminalTheme(for: frame.surfaceID),
                config: terminalConfigTheme(for: frame.surfaceID),
                revision: terminalThemeState.revisionsBySurfaceID[frame.surfaceID]
            )
        }
        return deliverTerminalOutput(
            TerminalOutputDelivery(
                renderGrid: deliveryFrame,
                replaceable: deliveryFrame.isReplaceableViewportPatchForMobileDelivery,
                viewportPolicy: deliveryFrame.mobileViewportPolicy
            ),
            surfaceID: surfaceID,
            bypassReplayBarrier: bypassReplayBarrier
        )
    }

    @discardableResult
    func deliverTerminalTheme(
        _ frame: MobileTerminalRenderGridFrame,
        surfaceID: String,
        bypassReplayBarrier: Bool = false
    ) -> Bool {
        deliverTerminalOutput(
            TerminalOutputDelivery(theme: frame),
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
                let isPartialVerifiedRenderGrid = terminalOutputTransport == .renderGrid
                    && supportedHostCapabilities.contains(Self.terminalVerifiedReplayCapability)
                    && delivery.sourceRenderGridFrame?.full == false
                guard !isPartialVerifiedRenderGrid else { return false }
                return deliverTerminalOutput(delivery, surfaceID: surfaceID, bypassReplayBarrier: true)
            }
            if remoteClient != nil,
               terminalReplayBarrierAckStreamTokensBySurfaceID[surfaceID] == nil,
               terminalViewportReplayBarrierPendingAckTokensBySurfaceID[surfaceID] == nil,
               !terminalReplaySurfaceIDsInFlight.contains(surfaceID),
               terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle != false,
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
        let enqueueResult = queue.enqueue(delivery)
        let pendingCount = queue.pendingCount
        terminalOutputQueuesBySurfaceID[surfaceID] = queue
        if enqueueResult == .overloaded {
            MobileDebugLog.anchormux(
                "terminal.output.overload surface=\(surfaceID) " +
                    "limit=\(TerminalOutputDeliveryQueue.maximumPendingCount)"
            )
            requestAuthoritativeTerminalResync(
                surfaceID: surfaceID,
                reason: "output_queue_overload",
                forceReplacementReplay: true
            )
            return false
        }
        if bypassReplayBarrier,
           case .immediate = enqueueResult,
           terminalReplayBarrierTokensBySurfaceID[surfaceID] != nil {
            terminalReplayBarrierAckStreamTokensBySurfaceID[surfaceID] = streamToken
        }
        if pendingCount == TerminalOutputDeliveryQueue.maximumPendingCount {
            MobileDebugLog.anchormux(
                "terminal.output.pending surface=\(surfaceID) depth=\(pendingCount)"
            )
        }
        if case .immediate(let immediate) = enqueueResult {
            continuation.yield(
                MobileTerminalOutputChunk(
                    data: immediate.bytes,
                    streamToken: streamToken,
                    viewportPolicy: immediate.viewportPolicy,
                    sourceRenderGridFrame: immediate.sourceRenderGridFrame,
                    endSequence: immediate.endSequence,
                    requiresVerifiedReplay: requiresVerifiedReplayApplication(for: immediate),
                    requiresVerifiedReplayReset: immediate.requiresVerifiedReplayReset,
                    terminalConfigTheme: immediate.terminalConfigTheme
                )
            )
        }
        return true
    }

    /// Whether a chunk must apply through the verified freeze/replay/verify/
    /// reveal pipeline. Screen-anchored primary-screen deltas apply directly:
    /// they are ordered by the same stateSeq floors, their scroll prologue
    /// feeds local scrollback, and skipping the per-frame Metal fence keeps
    /// streaming output from stalling a locally scrolling viewport. Fulls and
    /// alternate-screen frames keep the verified pipeline.
    private func requiresVerifiedReplayApplication(for delivery: TerminalOutputDelivery) -> Bool {
        if delivery.replayVerificationPolicy == .bestEffortCompatibility {
            return false
        }
        guard terminalOutputTransport == .renderGrid,
              supportedHostCapabilities.contains(Self.terminalVerifiedReplayCapability) else {
            return false
        }
        if usesScreenAnchoredRenderGrid,
           let frame = delivery.sourceRenderGridFrame,
           !frame.full,
           frame.anchor == .screen,
           frame.activeScreen == .primary {
            return false
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
            let droppedOutputDuringBarrier = terminalReplayBarrierDroppedOutputSurfaceIDs.contains(surfaceID)
            if droppedOutputDuringBarrier, needsFollowUpReplay {
                if claimTerminalReplayBarrierFollowUp(surfaceID: surfaceID) {
                    let preservingOverloadReplacement =
                        terminalReplayOverloadReplacementSurfaceIDs.contains(surfaceID)
                    let baselineReplayRequestCount = missingBaselineReplayBarrier
                        ? terminalRenderGridBaselineReplayRequestCountsBySurfaceID[surfaceID]
                        : nil
                    cancelTerminalReplayBarrierWatchdog(surfaceID: surfaceID)
                    terminalReplayBarrierAckStreamTokensBySurfaceID.removeValue(forKey: surfaceID)
                    terminalReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
                    terminalColdAttachReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
                    terminalRenderGridBaselineReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
                    MobileDebugLog.anchormux("terminal.output.replay_barrier_cleared surface=\(surfaceID)")
                    terminalReplayBarrierDroppedOutputSurfaceIDs.remove(surfaceID)
                    terminalReplayOverloadReplacementSurfaceIDs.remove(surfaceID)
                    terminalReplayBarrierDroppedOutputCountsBySurfaceID.removeValue(forKey: surfaceID)
                    let replayBarrierToken = beginTerminalReplayBarrier(
                        surfaceID: surfaceID,
                        preservingFollowUpCount: true,
                        preservingOverloadReplacement: preservingOverloadReplacement
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
                cancelTerminalReplayBarrierWatchdog(surfaceID: surfaceID)
                terminalReplayBarrierAckStreamTokensBySurfaceID.removeValue(forKey: surfaceID)
                terminalReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
                terminalColdAttachReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
                terminalRenderGridBaselineReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
                MobileDebugLog.anchormux("terminal.output.replay_barrier_cleared surface=\(surfaceID)")
                terminalReplayBarrierDroppedOutputSurfaceIDs.remove(surfaceID)
                terminalReplayOverloadReplacementSurfaceIDs.remove(surfaceID)
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
            viewportPolicy: next.viewportPolicy,
            sourceRenderGridFrame: next.sourceRenderGridFrame,
            endSequence: next.endSequence,
            requiresVerifiedReplay: requiresVerifiedReplayApplication(for: next),
            requiresVerifiedReplayReset: next.requiresVerifiedReplayReset,
            terminalConfigTheme: next.terminalConfigTheme
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
        terminalMirrorHydrationNeededSurfaceIDs.insert(surfaceID)
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
        terminalRenderGridHistoryContinuityBySurfaceID.removeValue(forKey: surfaceID)
        terminalMirrorHydrationNeededSurfaceIDs.insert(surfaceID)
        terminalAlternateRenderGridBaselineSurfaceIDs.remove(surfaceID)
        terminalFullReplacementSeqBySurfaceID.removeValue(forKey: surfaceID)
        terminalFullReplacementGenerationBySurfaceID.removeValue(forKey: surfaceID)
        cancelTerminalInputAckResubscribeRetry(surfaceID: surfaceID)
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
        terminalMirrorHydrationNeededSurfaceIDs.insert(surfaceID)
        MobileDebugLog.anchormux("terminal.output.replay_requested surface=\(surfaceID)")
        requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: replayBarrierToken)
    }

}

private extension MobileTerminalRenderGridFrame {
    func replacingThemeColors(
        with theme: TerminalTheme,
        config: TerminalTheme,
        revision: UInt64?
    ) -> Self {
        var frame = self
        let reverseColors = frame.modes.last(where: { !$0.ansi && $0.code == 5 })?.on == true
        let rawForeground = reverseColors ? theme.background : theme.foreground
        let rawBackground = reverseColors ? theme.foreground : theme.background
        frame.terminalForeground = rawForeground.caseInsensitiveCompare(config.foreground) == .orderedSame
            ? nil
            : rawForeground
        frame.terminalBackground = rawBackground.caseInsensitiveCompare(config.background) == .orderedSame
            ? nil
            : rawBackground
        let configuredCursor = switch config.cursorColorSemantic {
        case .foreground: theme.foreground
        case .background: theme.background
        case nil: config.cursor
        }
        frame.terminalCursorColor = theme.cursor.caseInsensitiveCompare(configuredCursor) == .orderedSame
            ? nil
            : theme.cursor
        frame.terminalTheme = theme
        frame.terminalConfigTheme = config
        frame.terminalThemeRevision = revision
        return frame
    }
}
