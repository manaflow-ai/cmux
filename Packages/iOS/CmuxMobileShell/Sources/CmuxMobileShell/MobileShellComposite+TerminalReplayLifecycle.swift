internal import CmuxMobileDiagnostics
public import Foundation

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
        if let pendingSeq = pendingTerminalByteEndSeqBySurfaceID[surfaceID],
           endSeq >= pendingSeq {
            pendingTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
            MobileDebugLog.anchormux("sync.input_seq_caught_up surface=\(surfaceID) seq=\(endSeq)")
        }
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
        preservingFollowUpCount: Bool = false
    ) -> UUID {
        cancelTerminalReplayInFlight(surfaceID: surfaceID)
        terminalColdReplayNeedsBarrierUpgradeSurfaceIDs.remove(surfaceID)
        terminalOutputQueuesBySurfaceID[surfaceID] = TerminalOutputDeliveryQueue()
        terminalOutputStreamTokensBySurfaceID[surfaceID] = UUID()
        deliveredTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        terminalFullReplacementSeqBySurfaceID.removeValue(forKey: surfaceID)
        terminalFullReplacementGenerationBySurfaceID.removeValue(forKey: surfaceID)
        pendingTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
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
        terminalReplayBarrierTokensInFlightBySurfaceID.removeValue(forKey: surfaceID)
        return token
    }

    func requestColdAttachTerminalReplay(surfaceID: String) {
        guard remoteClient != nil else {
            terminalColdReplayNeedsBarrierUpgradeSurfaceIDs.insert(surfaceID)
            return
        }
        if supportedHostCapabilities.contains(Self.terminalReplayCapability) {
            let replayBarrierToken = beginTerminalReplayBarrier(surfaceID: surfaceID)
            requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: replayBarrierToken)
            return
        }
        if supportedHostCapabilities.isEmpty {
            terminalColdReplayNeedsBarrierUpgradeSurfaceIDs.insert(surfaceID)
        } else {
            terminalColdReplayNeedsBarrierUpgradeSurfaceIDs.remove(surfaceID)
        }
        requestTerminalReplay(surfaceID: surfaceID)
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
                requestTerminalReplay(surfaceID: surfaceID)
                continue
            }
            guard terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil else { continue }
            guard !terminalReplaySurfaceIDsInFlight.contains(surfaceID) else {
                // The pre-capability cold replay is already in flight.
                // Beginning a barrier here would cancel it and discard its
                // authoritative response, dropping the surface's first frame;
                // let it land unbarriered instead.
                continue
            }
            let replayBarrierToken = beginTerminalReplayBarrier(surfaceID: surfaceID)
            requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: replayBarrierToken)
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
        terminalReplayBarrierAckStreamTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierDroppedOutputSurfaceIDs.remove(surfaceID)
        terminalReplayBarrierDroppedOutputCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierAckCoveredDroppedOutputCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalViewportReplayBarrierPendingAckTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayFailureRetryCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierFollowUpCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierTokensInFlightBySurfaceID.removeValue(forKey: surfaceID)
        MobileDebugLog.anchormux("terminal.output.replay_barrier_cleared_\(reason) surface=\(surfaceID)")
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
}
