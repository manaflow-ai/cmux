internal import CmuxMobileDiagnostics
import Foundation

/// Terminal replay barrier and replay-request lifecycle for
/// `MobileShellComposite`: delivered-sequence bookkeeping, full-grid
/// replacement observation, cold-attach replay barrier upgrades, barrier
/// begin/clear/preserve, failure retries, and in-flight replay task tracking.
///
/// Lives in an extension file (with the replay lifecycle storage widened to
/// internal) instead of `MobileShellComposite.swift` to respect that file's
/// length budget.
extension MobileShellComposite {
    func markTerminalBytesDelivered(
        surfaceID: String,
        endSeq: UInt64,
        fullReplacement: Bool = false
    ) {
        let current = deliveredTerminalByteEndSeqBySurfaceID[surfaceID]
        let currentSeq = current ?? 0
        if current == nil || endSeq > currentSeq {
            deliveredTerminalByteEndSeqBySurfaceID[surfaceID] = endSeq
            if fullReplacement {
                markTerminalFullReplacementObserved(surfaceID: surfaceID, seq: endSeq)
            } else {
                clearTerminalFullReplacementObservationIfCovered(surfaceID: surfaceID, endSeq: endSeq)
            }
        } else if endSeq == currentSeq, fullReplacement {
            markTerminalFullReplacementObserved(surfaceID: surfaceID, seq: endSeq)
        }
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
            pendingTerminalInputDroppedRenderGridSurfaceIDs.remove(surfaceID)
            terminalReplayFailureRetryCountsBySurfaceID.removeValue(forKey: surfaceID)
            MobileDebugLog.anchormux("sync.input_seq_caught_up surface=\(surfaceID) seq=\(endSeq)")
            terminalSyncDiagnostics.gateResolved(
                surface: Self.diagnosticSurfaceHandle(surfaceID),
                gate: .pendingInputSeq,
                how: .catchupFrame,
                transport: terminalOutputTransport.debugName
            )
        }
        terminalSyncDiagnostics.frameApplied(
            surface: Self.diagnosticSurfaceHandle(surfaceID),
            transport: terminalOutputTransport.debugName
        )
    }

    func markTerminalFullReplacementObserved(surfaceID: String, seq: UInt64) {
        terminalFullReplacementSeqBySurfaceID[surfaceID] = seq
        terminalFullReplacementGeneration &+= 1
        terminalFullReplacementGenerationBySurfaceID[surfaceID] = terminalFullReplacementGeneration
    }

    private func clearTerminalFullReplacementObservationIfCovered(surfaceID: String, endSeq: UInt64) {
        guard let fullReplacementSeq = terminalFullReplacementSeqBySurfaceID[surfaceID],
              endSeq > fullReplacementSeq else {
            return
        }
        terminalFullReplacementSeqBySurfaceID.removeValue(forKey: surfaceID)
        terminalFullReplacementGenerationBySurfaceID.removeValue(forKey: surfaceID)
    }

    func beginTerminalReplayBarrier(
        surfaceID: String,
        preservingFollowUpCount: Bool = false,
        trigger: MobileTerminalSyncDiagnostics.ReplayTrigger = .barrier
    ) -> UUID {
        cancelTerminalReplayInFlight(surfaceID: surfaceID)
        terminalColdReplayNeedsBarrierUpgradeSurfaceIDs.remove(surfaceID)
        terminalOutputQueuesBySurfaceID[surfaceID] = TerminalOutputDeliveryQueue()
        terminalOutputStreamTokensBySurfaceID[surfaceID] = UUID()
        stashTerminalPreBarrierDeliveredEndSeq(surfaceID: surfaceID)
        deliveredTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        terminalRenderGridBaselineReplayRequestCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalRenderGridBaselineReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
        // The alternate baseline flag survives here: the surface keeps its
        // content under a barrier; only the surface-destroying resets clear it.
        terminalFullReplacementSeqBySurfaceID.removeValue(forKey: surfaceID)
        terminalFullReplacementGenerationBySurfaceID.removeValue(forKey: surfaceID)
        pendingTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        pendingTerminalInputDroppedRenderGridSurfaceIDs.remove(surfaceID)
        let token = UUID()
        terminalReplayBarrierTokensBySurfaceID[surfaceID] = token
        terminalReplayBarrierAckStreamTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierDroppedOutputSurfaceIDs.remove(surfaceID)
        terminalReplayBarrierDroppedOutputCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierAckCoveredDroppedOutputCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalViewportReplayBarrierPendingAckTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayFailureRetryCountsBySurfaceID.removeValue(forKey: surfaceID)
        if !preservingFollowUpCount {
            terminalReplayBarrierFollowUpCountsBySurfaceID.removeValue(forKey: surfaceID)
        }
        terminalColdAttachReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierTokensInFlightBySurfaceID.removeValue(forKey: surfaceID)
        terminalSyncDiagnostics.barrierArmed(
            surface: Self.diagnosticSurfaceHandle(surfaceID),
            trigger: trigger
        )
        return token
    }

    func requestColdAttachTerminalReplay(surfaceID: String) {
        guard remoteClient != nil else {
            terminalColdReplayNeedsBarrierUpgradeSurfaceIDs.insert(surfaceID)
            return
        }
        if supportedHostCapabilities.contains(Self.terminalReplayCapability) {
            let replayBarrierToken = beginTerminalReplayBarrier(surfaceID: surfaceID, trigger: .coldAttach)
            terminalColdAttachReplayBarrierTokensBySurfaceID[surfaceID] = replayBarrierToken
            requestTerminalReplay(
                surfaceID: surfaceID,
                replayBarrierToken: replayBarrierToken,
                trigger: .coldAttach
            )
            return
        }
        if supportedHostCapabilities.isEmpty {
            terminalColdReplayNeedsBarrierUpgradeSurfaceIDs.insert(surfaceID)
        } else {
            terminalColdReplayNeedsBarrierUpgradeSurfaceIDs.remove(surfaceID)
        }
        requestTerminalReplay(surfaceID: surfaceID, trigger: .coldAttach)
    }

    func upgradePendingColdTerminalReplaysIfNeeded() {
        guard !terminalColdReplayNeedsBarrierUpgradeSurfaceIDs.isEmpty else { return }
        let surfaceIDs = terminalColdReplayNeedsBarrierUpgradeSurfaceIDs
        terminalColdReplayNeedsBarrierUpgradeSurfaceIDs = []
        let barrierCapable = supportedHostCapabilities.contains(Self.terminalReplayCapability)
        for surfaceID in surfaceIDs where hasTerminalOutputSink(surfaceID: surfaceID) {
            guard barrierCapable else {
                // Hosts that answer mobile.terminal.replay without advertising
                // terminal.replay.v1 still need the pre-connection mount's cold
                // replay; mirror the unbarriered fallback used when mounting
                // after the connection resolved.
                requestTerminalReplay(surfaceID: surfaceID, trigger: .coldAttach)
                continue
            }
            guard terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil else { continue }
            let replayBarrierToken = beginTerminalReplayBarrier(surfaceID: surfaceID, trigger: .coldAttach)
            terminalColdAttachReplayBarrierTokensBySurfaceID[surfaceID] = replayBarrierToken
            requestTerminalReplay(
                surfaceID: surfaceID,
                replayBarrierToken: replayBarrierToken,
                trigger: .coldAttach
            )
        }
    }

    @discardableResult
    func clearTerminalReplayBarrierIfCurrent(
        surfaceID: String,
        token: UUID?,
        reason: String,
        preserveDroppedOutput: Bool = false
    ) -> Bool {
        guard let token,
              terminalReplayBarrierTokensBySurfaceID[surfaceID] == token else {
            return false
        }
        if preserveDroppedOutput,
           terminalReplayBarrierDroppedOutputSurfaceIDs.contains(surfaceID) {
            MobileDebugLog.anchormux("terminal.output.replay_barrier_preserved_\(reason) surface=\(surfaceID)")
            return false
        }
        let wasMissingBaselineBarrier = terminalRenderGridBaselineReplayBarrierTokensBySurfaceID[surfaceID] == token
        // Restoring the floor keeps later deltas flowing instead of stalling
        // them behind an exhausted missing-baseline budget.
        let restoredBaselineFromFloor = restoreTerminalPreBarrierBaselineIfNeeded(surfaceID: surfaceID)
        // A restored baseline is NOT a delivered one for budget purposes: the
        // gate that armed this barrier is still unsatisfied, and clearing the
        // budget here would let an empty-answering host be hammered with one
        // replay per gated delta.
        let baselineDelivered = terminalOutputTransport == .hybrid
            ? terminalAlternateRenderGridBaselineSurfaceIDs.contains(surfaceID)
            : (!restoredBaselineFromFloor && deliveredTerminalByteEndSeqBySurfaceID[surfaceID] != nil)
        terminalReplayBarrierAckStreamTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierDroppedOutputSurfaceIDs.remove(surfaceID)
        terminalReplayBarrierDroppedOutputCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierAckCoveredDroppedOutputCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalViewportReplayBarrierPendingAckTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayFailureRetryCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierFollowUpCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalColdAttachReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
        if !wasMissingBaselineBarrier || baselineDelivered {
            terminalRenderGridBaselineReplayRequestCountsBySurfaceID.removeValue(forKey: surfaceID)
        }
        terminalRenderGridBaselineReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierTokensInFlightBySurfaceID.removeValue(forKey: surfaceID)
        MobileDebugLog.anchormux("terminal.output.replay_barrier_cleared_\(reason) surface=\(surfaceID)")
        terminalSyncDiagnostics.barrierCleared(
            surface: Self.diagnosticSurfaceHandle(surfaceID),
            reason: .from(reason),
            transport: terminalOutputTransport.debugName
        )
        return true
    }

    @discardableResult
    func preserveTerminalReplayBarrierIfCurrent(
        surfaceID: String,
        token: UUID?,
        reason: String
    ) -> Bool {
        guard let token,
              terminalReplayBarrierTokensBySurfaceID[surfaceID] == token else {
            return false
        }
        terminalReplayBarrierAckStreamTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierTokensInFlightBySurfaceID.removeValue(forKey: surfaceID)
        MobileDebugLog.anchormux("terminal.output.replay_barrier_preserved_\(reason) surface=\(surfaceID)")
        let viewportBarrierPending = terminalViewportReplayBarrierPendingAckTokensBySurfaceID[surfaceID] != nil
        let barrierReason = MobileTerminalSyncDiagnostics.BarrierReason.from(reason)
        terminalSyncDiagnostics.barrierPreserved(
            surface: Self.diagnosticSurfaceHandle(surfaceID),
            reason: barrierReason
        )
        if viewportBarrierPending {
            terminalSyncDiagnostics.viewportBarrierOutcome(
                .leakedPreserved,
                surface: Self.diagnosticSurfaceHandle(surfaceID)
            )
        }
        return true
    }

    func prepareTerminalReplayFailureRetry(
        surfaceID: String,
        replayBarrierToken: UUID?
    ) -> UUID? {
        guard let replayBarrierToken,
              hasTerminalOutputSink(surfaceID: surfaceID),
              terminalReplayBarrierTokensBySurfaceID[surfaceID] == replayBarrierToken else {
            return nil
        }
        let retryCount = terminalReplayFailureRetryCountsBySurfaceID[surfaceID] ?? 0
        guard retryCount < Self.maxTerminalReplayFailureRetries else {
            MobileDebugLog.anchormux(
                "CMUX_REPLAY retry_exhausted surface=\(surfaceID) attempts=\(retryCount)"
            )
            terminalSyncDiagnostics.replayRetryExhausted(
                surface: Self.diagnosticSurfaceHandle(surfaceID),
                trigger: .barrier,
                attempts: retryCount,
                followups: terminalReplayBarrierFollowUpCountsBySurfaceID[surfaceID] ?? 0
            )
            return nil
        }
        terminalReplayFailureRetryCountsBySurfaceID[surfaceID] = retryCount + 1
        MobileDebugLog.anchormux(
            "CMUX_REPLAY retry_after_failure surface=\(surfaceID) attempt=\(retryCount + 1)"
        )
        return replayBarrierToken
    }

    func terminalReplayFailureRetryExhausted(surfaceID: String) -> Bool {
        (terminalReplayFailureRetryCountsBySurfaceID[surfaceID] ?? 0) >= Self.maxTerminalReplayFailureRetries
    }

    @discardableResult
    func requestTerminalReplayForCurrentBarrier(
        surfaceID: String,
        replayBarrierToken: UUID?,
        coveredReplayBarrierDroppedOutputCount: UInt64?,
        reason: String
    ) -> Bool {
        guard let replayBarrierToken,
              hasTerminalOutputSink(surfaceID: surfaceID),
              terminalReplayBarrierTokensBySurfaceID[surfaceID] == replayBarrierToken,
              remoteClient != nil else {
            return false
        }
        MobileDebugLog.anchormux("CMUX_REPLAY retry_\(reason) surface=\(surfaceID)")
        requestTerminalReplay(
            surfaceID: surfaceID,
            replayBarrierToken: replayBarrierToken,
            coveredReplayBarrierDroppedOutputCount: coveredReplayBarrierDroppedOutputCount
        )
        return true
    }

    func markTerminalReplayInFlight(
        surfaceID: String,
        requestID: UUID,
        replayBarrierToken: UUID?
    ) {
        cancelTerminalReplayInFlight(surfaceID: surfaceID)
        terminalReplaySurfaceIDsInFlight.insert(surfaceID)
        terminalReplayRequestIDsInFlightBySurfaceID[surfaceID] = requestID
        if let replayBarrierToken {
            terminalReplayBarrierTokensInFlightBySurfaceID[surfaceID] = replayBarrierToken
        } else {
            terminalReplayBarrierTokensInFlightBySurfaceID.removeValue(forKey: surfaceID)
        }
    }

    func storeTerminalReplayTask(
        surfaceID: String,
        requestID: UUID,
        task: Task<Void, Never>
    ) {
        guard terminalReplayRequestIDsInFlightBySurfaceID[surfaceID] == requestID else {
            task.cancel()
            return
        }
        terminalReplayTasksBySurfaceID[surfaceID] = task
    }

    func clearTerminalReplayInFlightIfCurrent(surfaceID: String, requestID: UUID) {
        guard terminalReplayRequestIDsInFlightBySurfaceID[surfaceID] == requestID else { return }
        terminalReplaySurfaceIDsInFlight.remove(surfaceID)
        terminalReplayRequestIDsInFlightBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayTasksBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierTokensInFlightBySurfaceID.removeValue(forKey: surfaceID)
    }

    func cancelTerminalReplayInFlight(surfaceID: String) {
        terminalReplayTasksBySurfaceID.removeValue(forKey: surfaceID)?.cancel()
        terminalReplaySurfaceIDsInFlight.remove(surfaceID)
        terminalReplayRequestIDsInFlightBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierTokensInFlightBySurfaceID.removeValue(forKey: surfaceID)
    }

    func cancelAllTerminalReplayTasks() {
        for task in terminalReplayTasksBySurfaceID.values {
            task.cancel()
        }
        terminalReplayTasksBySurfaceID = [:]
        terminalReplaySurfaceIDsInFlight = []
        terminalReplayRequestIDsInFlightBySurfaceID = [:]
        terminalReplayBarrierTokensInFlightBySurfaceID = [:]
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
        let replayBarrierToken = beginTerminalReplayBarrier(surfaceID: surfaceID, trigger: .baseline)
        terminalRenderGridBaselineReplayRequestCountsBySurfaceID[surfaceID] = requestCount + 1
        terminalRenderGridBaselineReplayBarrierTokensBySurfaceID[surfaceID] = replayBarrierToken
        requestTerminalReplay(
            surfaceID: surfaceID,
            replayBarrierToken: replayBarrierToken,
            trigger: .baseline
        )
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

    /// Barrier released without delivering: the surface still shows the
    /// pre-barrier content, so the stashed floor IS the truthful baseline.
    /// Restores it (returning whether it did) and always drops the floor.
    @discardableResult
    func restoreTerminalPreBarrierBaselineIfNeeded(surfaceID: String) -> Bool {
        var restored = false
        if deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == nil,
           let floorSeq = terminalPreBarrierDeliveredEndSeqBySurfaceID[surfaceID] {
            deliveredTerminalByteEndSeqBySurfaceID[surfaceID] = floorSeq
            restored = true
        }
        terminalPreBarrierDeliveredEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        return restored
    }

    /// Move the delivered high-water mark into the pre-barrier stale floor so
    /// buffered pre-barrier frames stay rejected while the replay is pending.
    func stashTerminalPreBarrierDeliveredEndSeq(surfaceID: String) {
        guard let deliveredSeq = deliveredTerminalByteEndSeqBySurfaceID[surfaceID] else { return }
        let stashedSeq = terminalPreBarrierDeliveredEndSeqBySurfaceID[surfaceID] ?? 0
        terminalPreBarrierDeliveredEndSeqBySurfaceID[surfaceID] = max(stashedSeq, deliveredSeq)
    }
}
