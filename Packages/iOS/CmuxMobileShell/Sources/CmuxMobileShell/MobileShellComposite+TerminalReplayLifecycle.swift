internal import CmuxMobileDiagnostics
internal import CmuxMobileRPC
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
            cancelTerminalInputAckResubscribeRetry(surfaceID: surfaceID)
            pendingTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
            pendingTerminalInputDroppedRenderGridSurfaceIDs.remove(surfaceID)
            terminalReplayFailureRetryCountsBySurfaceID.removeValue(forKey: surfaceID)
            MobileDebugLog.anchormux("sync.input_seq_caught_up surface=\(surfaceID) seq=\(endSeq)")
        }
        resumeTerminalLaneIfSuspended(surfaceID: surfaceID)
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
        preservingOverloadReplacement: Bool = false
    ) -> UUID {
        // The overload marker describes still-unreconciled dropped work, not a
        // particular barrier token. Carry it when a live barrier is replaced;
        // otherwise a superseding resync could accept a compatibility payload
        // as though it covered the discarded queue.
        let carryOverloadReplacement = preservingOverloadReplacement
            || terminalReplayOverloadReplacementSurfaceIDs.contains(surfaceID)
        cancelTerminalReplayBarrierWatchdog(surfaceID: surfaceID)
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
        cancelTerminalInputAckResubscribeRetry(surfaceID: surfaceID)
        pendingTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        pendingTerminalInputDroppedRenderGridSurfaceIDs.remove(surfaceID)
        let token = UUID()
        terminalReplayBarrierTokensBySurfaceID[surfaceID] = token
        terminalReplayBarrierAckStreamTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierDroppedOutputSurfaceIDs.remove(surfaceID)
        terminalReplayOverloadReplacementSurfaceIDs.remove(surfaceID)
        terminalReplayBarrierDroppedOutputCountsBySurfaceID.removeValue(forKey: surfaceID)
        if carryOverloadReplacement {
            // The overload marker represents output discarded before this
            // barrier generation, not merely a property of the old token.
            // Preserve a nonzero owed-output floor alongside it so a
            // compatibility fallback can never be mistaken for an
            // authoritative full replacement on a follow-up barrier.
            terminalReplayOverloadReplacementSurfaceIDs.insert(surfaceID)
            terminalReplayBarrierDroppedOutputSurfaceIDs.insert(surfaceID)
            terminalReplayBarrierDroppedOutputCountsBySurfaceID[surfaceID] = 1
        }
        terminalReplayBarrierAckCoveredDroppedOutputCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalViewportReplayBarrierPendingAckTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayFailureRetryCountsBySurfaceID.removeValue(forKey: surfaceID)
        if !preservingFollowUpCount {
            terminalReplayBarrierFollowUpCountsBySurfaceID.removeValue(forKey: surfaceID)
        }
        terminalColdAttachReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierTokensInFlightBySurfaceID.removeValue(forKey: surfaceID)
        return token
    }

    /// Begin a fresh authoritative-replay generation while carrying forward
    /// any output or replay work that the new generation supersedes.
    func beginTerminalReplayBarrierCarryingReplacedWork(
        surfaceID: String,
        forceReplacementReplay: Bool = false
    ) -> UUID {
        let preservingOverloadReplacement = terminalReplayOverloadReplacementSurfaceIDs.contains(surfaceID)
        let owesReplacementReplay = forceReplacementReplay
            || !(terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle ?? true)
            || terminalReplaySurfaceIDsInFlight.contains(surfaceID)
            || terminalReplayBarrierTokensBySurfaceID[surfaceID] != nil
        let replayBarrierToken = beginTerminalReplayBarrier(
            surfaceID: surfaceID,
            preservingOverloadReplacement: preservingOverloadReplacement
        )
        if owesReplacementReplay {
            terminalReplayBarrierDroppedOutputSurfaceIDs.insert(surfaceID)
            // A forced replacement (notably an output-queue overload) has
            // already discarded work before this barrier was created. Keep a
            // non-zero floor so a compatibility replay fallback cannot be
            // mistaken for covering zero dropped chunks.
            if forceReplacementReplay {
                terminalReplayOverloadReplacementSurfaceIDs.insert(surfaceID)
                terminalReplayBarrierDroppedOutputCountsBySurfaceID[surfaceID] = max(
                    terminalReplayBarrierDroppedOutputCountsBySurfaceID[surfaceID] ?? 0,
                    1
                )
            }
        }
        return replayBarrierToken
    }

    /// Supersede every older replay and output acknowledgement for a surface,
    /// then request one authoritative replacement owned by the new barrier.
    func requestAuthoritativeTerminalResync(
        surfaceID: String,
        reason: String,
        forceReplacementReplay: Bool = false
    ) {
        guard hasTerminalOutputSink(surfaceID: surfaceID) else { return }
        let replayBarrierToken = beginTerminalReplayBarrierCarryingReplacedWork(
            surfaceID: surfaceID,
            forceReplacementReplay: forceReplacementReplay
        )
        MobileDebugLog.anchormux(
            "CMUX_REPLAY authoritative_resync reason=\(reason) surface=\(surfaceID)"
        )
        requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: replayBarrierToken)
    }

    /// Retry a replay whose payload cannot replace output discarded by a
    /// recovery barrier. Raw byte tails and VT text snapshots are useful for a
    /// blank/legacy cold attach, but neither carries the complete render-grid
    /// state required to replace a live TUI after overload.
    ///
    /// - Returns: `true` when the current request's in-flight ownership was
    ///   transferred to a replacement request.
    @discardableResult
    func retryTerminalReplayAfterNonAuthoritativeFallback(
        surfaceID: String,
        replayBarrierToken: UUID?,
        replayRequestID: UUID,
        coveredReplayBarrierDroppedOutputCount: UInt64?
    ) -> Bool {
        guard let replayBarrierToken,
              terminalReplayBarrierDroppedOutputSurfaceIDs.contains(surfaceID),
              terminalReplayBarrierTokensBySurfaceID[surfaceID] == replayBarrierToken else {
            return false
        }
        guard let retryToken = prepareTerminalReplayFailureRetry(
            surfaceID: surfaceID,
            replayBarrierToken: replayBarrierToken
        ) else {
            // `prepareTerminalReplayFailureRetry` fails the barrier open when
            // the bounded retry budget is exhausted. The old local frame is
            // preserved and live output can re-establish it without a manual
            // disconnect/reconnect.
            return false
        }
        clearTerminalReplayInFlightIfCurrent(
            surfaceID: surfaceID,
            requestID: replayRequestID
        )
        requestTerminalReplay(
            surfaceID: surfaceID,
            replayBarrierToken: retryToken,
            coveredReplayBarrierDroppedOutputCount:
                coveredReplayBarrierDroppedOutputCount
                    ?? terminalReplayBarrierDroppedOutputCountsBySurfaceID[surfaceID]
        )
        return true
    }

    func requestColdAttachTerminalReplay(surfaceID: String) {
        guard remoteClient != nil else {
            terminalColdReplayNeedsBarrierUpgradeSurfaceIDs.insert(surfaceID)
            return
        }
        if supportedHostCapabilities.contains(Self.terminalReplayCapability) {
            let replayBarrierToken = beginTerminalReplayBarrier(surfaceID: surfaceID)
            terminalColdAttachReplayBarrierTokensBySurfaceID[surfaceID] = replayBarrierToken
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
            let replayBarrierToken = beginTerminalReplayBarrier(surfaceID: surfaceID)
            terminalColdAttachReplayBarrierTokensBySurfaceID[surfaceID] = replayBarrierToken
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
        cancelTerminalReplayBarrierWatchdog(surfaceID: surfaceID)
        if preserveDroppedOutput,
           terminalReplayBarrierDroppedOutputSurfaceIDs.contains(surfaceID) {
            if terminalReplayFailureRetryExhausted(surfaceID: surfaceID) {
                return failOpenTerminalReplayBarrier(
                    surfaceID: surfaceID,
                    token: token,
                    reason: "\(reason)_retry_exhausted"
                )
            }
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
        terminalReplayOverloadReplacementSurfaceIDs.remove(surfaceID)
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

    /// A replay may report the phone's viewport without already owning a
    /// barrier (for example, a byte-gap recovery). If the Mac is between two
    /// sizes, keep the current pixels and create a lightweight barrier whose
    /// next authoritative full grid owns the retry. Do not call
    /// ``beginTerminalReplayBarrier`` here: that method resets the output
    /// stream and cancels the task that is currently classifying this error.
    @discardableResult
    func armTerminalReplayBarrierForViewportTransition(
        surfaceID: String,
        token: UUID?
    ) -> UUID? {
        guard hasTerminalOutputSink(surfaceID: surfaceID) else { return nil }
        if let token {
            guard terminalReplayBarrierTokensBySurfaceID[surfaceID] == token else {
                return nil
            }
            terminalReplayBarrierDroppedOutputSurfaceIDs.insert(surfaceID)
            armTerminalReplayBarrierWatchdog(surfaceID: surfaceID, token: token)
            _ = preserveTerminalReplayBarrierIfCurrent(
                surfaceID: surfaceID,
                token: token,
                reason: "viewport_transition"
            )
            return token
        }
        if let existingToken = terminalReplayBarrierTokensBySurfaceID[surfaceID] {
            terminalReplayBarrierDroppedOutputSurfaceIDs.insert(surfaceID)
            armTerminalReplayBarrierWatchdog(
                surfaceID: surfaceID,
                token: existingToken
            )
            _ = preserveTerminalReplayBarrierIfCurrent(
                surfaceID: surfaceID,
                token: existingToken,
                reason: "viewport_transition_existing"
            )
            return existingToken
        }
        let barrierToken = UUID()
        terminalReplayBarrierTokensBySurfaceID[surfaceID] = barrierToken
        terminalReplayBarrierAckStreamTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierAckCoveredDroppedOutputCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierTokensInFlightBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayFailureRetryCountsBySurfaceID.removeValue(forKey: surfaceID)
        // The failed request itself is the replaced work. Mark it owed so the
        // first settled full grid cannot be treated as an ordinary live frame.
        terminalReplayBarrierDroppedOutputSurfaceIDs.insert(surfaceID)
        armTerminalReplayBarrierWatchdog(
            surfaceID: surfaceID,
            token: barrierToken
        )
        MobileDebugLog.anchormux(
            "terminal.output.replay_barrier_armed_viewport_transition surface=\(surfaceID)"
        )
        return barrierToken
    }

    /// Fails a stuck replay barrier open so live output can re-establish state.
    ///
    /// Intact-surface barriers restore the pre-barrier delivered floor because
    /// the local terminal still shows that content. Surface-reset paths call
    /// ``rebaseTerminalReplayStaleFloor(surfaceID:)`` before failing open, so
    /// they keep the erase-and-rebase behavior for a blank rebuilt surface.
    ///
    /// Result invariant: no code path may leave a surface where live output is
    /// dropped indefinitely while no replay is in flight and no retry budget
    /// remains.
    @discardableResult
    func failOpenTerminalReplayBarrier(
        surfaceID: String,
        token: UUID? = nil,
        reason: String
    ) -> Bool {
        if let token, terminalReplayBarrierTokensBySurfaceID[surfaceID] != token {
            return false
        }
        guard terminalReplayBarrierTokensBySurfaceID[surfaceID] != nil else {
            return false
        }
        cancelTerminalReplayBarrierWatchdog(surfaceID: surfaceID)
        cancelTerminalReplayInFlight(surfaceID: surfaceID)
        terminalReplayBarrierAckStreamTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierDroppedOutputSurfaceIDs.remove(surfaceID)
        terminalReplayOverloadReplacementSurfaceIDs.remove(surfaceID)
        terminalReplayBarrierDroppedOutputCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierAckCoveredDroppedOutputCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalViewportReplayBarrierPendingAckTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayFailureRetryCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierFollowUpCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalColdAttachReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalRenderGridBaselineReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierTokensInFlightBySurfaceID.removeValue(forKey: surfaceID)
        restoreTerminalPreBarrierBaselineIfNeeded(surfaceID: surfaceID)
        cancelTerminalInputAckResubscribeRetry(surfaceID: surfaceID)
        pendingTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        pendingTerminalInputDroppedRenderGridSurfaceIDs.remove(surfaceID)
        MobileDebugLog.anchormux("terminal.output.replay_barrier_fail_open surface=\(surfaceID) reason=\(reason)")
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
            failOpenTerminalReplayBarrier(
                surfaceID: surfaceID,
                token: replayBarrierToken,
                reason: "retry_exhausted"
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
        cancelTerminalReplayBarrierWatchdog(surfaceID: surfaceID)
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
        cancelAllTerminalReplayBarrierWatchdogs()
    }

    func cancelTerminalReplayBarrierWatchdog(surfaceID: String) {
        terminalReplayBarrierWatchdogTasksBySurfaceID
            .removeValue(forKey: surfaceID)?
            .cancel()
        terminalReplayBarrierWatchdogIDsBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierWatchdogTokensBySurfaceID.removeValue(forKey: surfaceID)
    }

    func cancelAllTerminalReplayBarrierWatchdogs() {
        for task in terminalReplayBarrierWatchdogTasksBySurfaceID.values {
            task.cancel()
        }
        terminalReplayBarrierWatchdogTasksBySurfaceID = [:]
        terminalReplayBarrierWatchdogIDsBySurfaceID = [:]
        terminalReplayBarrierWatchdogTokensBySurfaceID = [:]
    }

    func armTerminalReplayBarrierWatchdog(
        surfaceID: String,
        token: UUID
    ) {
        guard terminalReplayBarrierTokensBySurfaceID[surfaceID] == token else {
            return
        }
        if terminalReplayBarrierWatchdogTasksBySurfaceID[surfaceID] != nil,
           terminalReplayBarrierWatchdogTokensBySurfaceID[surfaceID] == token {
            // Re-registering a replacement output consumer must preserve the
            // original deadline. Resetting this task on every registration
            // can keep a blocked surface alive forever under repeated churn.
            return
        }
        cancelTerminalReplayBarrierWatchdog(surfaceID: surfaceID)
        let watchdogID = UUID()
        terminalReplayBarrierWatchdogIDsBySurfaceID[surfaceID] = watchdogID
        terminalReplayBarrierWatchdogTokensBySurfaceID[surfaceID] = token
        let clock = controlPlaneSchedulingClock
        terminalReplayBarrierWatchdogTasksBySurfaceID[surfaceID] = Task {
            @MainActor [weak self] in
            var shouldRearmAfterTimeout = false
            defer {
                if let self,
                   self.terminalReplayBarrierWatchdogIDsBySurfaceID[surfaceID]
                     == watchdogID {
                    self.terminalReplayBarrierWatchdogIDsBySurfaceID
                        .removeValue(forKey: surfaceID)
                    self.terminalReplayBarrierWatchdogTasksBySurfaceID
                        .removeValue(forKey: surfaceID)
                    self.terminalReplayBarrierWatchdogTokensBySurfaceID
                        .removeValue(forKey: surfaceID)
                    if shouldRearmAfterTimeout {
                        self.armTerminalReplayBarrierWatchdog(
                            surfaceID: surfaceID,
                            token: token
                        )
                    }
                }
            }
            do {
                try await clock.sleep(
                    for: Self.terminalReplayViewportTransitionWatchdogTimeout,
                    tolerance: nil
                )
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.terminalReplayBarrierWatchdogIDsBySurfaceID[surfaceID]
                    == watchdogID,
                  self.terminalReplayBarrierTokensBySurfaceID[surfaceID] == token else {
                return
            }
            MobileDebugLog.anchormux(
                "terminal.output.replay_barrier_viewport_transition_retry surface=\(surfaceID)"
            )
            guard let retryToken = self.prepareTerminalReplayFailureRetry(
                surfaceID: surfaceID,
                replayBarrierToken: token
            ) else {
                // The retry helper fail-opens the barrier when this bounded
                // viewport-transition episode has exhausted its budget.
                return
            }
            shouldRearmAfterTimeout = !self.requestTerminalReplayForCurrentBarrier(
                surfaceID: surfaceID,
                replayBarrierToken: retryToken,
                coveredReplayBarrierDroppedOutputCount: nil,
                reason: "viewport_transition_timeout"
            )
        }
    }

    func resolveTerminalReplayFailureBarrier(surfaceID: String, token: UUID?) {
        let coldAttachBarrier = token.map {
            terminalColdAttachReplayBarrierTokensBySurfaceID[surfaceID] == $0
        } ?? false
        let missingBaselineBarrier = token.map {
            terminalRenderGridBaselineReplayBarrierTokensBySurfaceID[surfaceID] == $0
        } ?? false
        guard coldAttachBarrier || missingBaselineBarrier else {
            failOpenTerminalReplayBarrier(surfaceID: surfaceID, token: token, reason: "failed")
            return
        }
        if clearTerminalReplayBarrierIfCurrent(surfaceID: surfaceID, token: token, reason: "cold_attach_failed") {
            if deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == nil {
                terminalRenderGridBaselineReplayRequestCountsBySurfaceID[surfaceID] = Self.maxTerminalReplayFailureRetries
            }
        }
    }

    /// The Mac returns this while Ghostty is between two viewport sizes. It is
    /// a readiness signal: the next authoritative render-grid event carries
    /// the settled geometry and must drive replay recovery.
    func isTerminalReplayViewportTransition(_ error: any Error) -> Bool {
        guard let connectionError = error as? MobileShellConnectionError,
              case let .rpcError(code, _) = connectionError else {
            return false
        }
        return code == "viewport_transition"
    }

    func requestTerminalReplayForMissingRenderGridBaseline(surfaceID: String) {
        let requestCount = terminalRenderGridBaselineReplayRequestCountsBySurfaceID[surfaceID] ?? 0
        guard terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil,
              !terminalReplaySurfaceIDsInFlight.contains(surfaceID),
              // A pending-input episode that already exhausted replay repair
              // must fail open instead of immediately re-entering through the
              // missing-baseline path; the next full live frame re-establishes
              // the baseline.
              !terminalReplayFailureRetryExhausted(surfaceID: surfaceID),
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
