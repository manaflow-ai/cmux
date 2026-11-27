import CMUXMobileCore
import Foundation

// MobileCoreRPCSession's control-stream repair: replacing a silent control stream and
// verifying the replacement.
extension MobileCoreRPCSession {
    // MARK: - control-stream repair

    private func isAwaitingResponse(_ requestID: String) -> Bool {
        if pending[requestID] != nil { return true }
        switch pipelinedPending[requestID] {
        case .pending, .awaiting:
            return true
        case .settled, nil:
            return false
        }
    }

    func noteControlFrameWritten(_ write: PendingWrite, generation: UInt64) {
        guard isAwaitingResponse(write.requestID) else { return }
        writtenControlFrameSequence &+= 1
        writtenControlFrames[write.requestID] = WrittenControlFrame(
            frame: write.frame,
            generation: generation,
            sequence: writtenControlFrameSequence
        )
        if generation < repairedControlStreamGeneration {
            resolveControlFramesStranded(before: repairedControlStreamGeneration)
        }
    }

    /// Replaces a silent control stream on the same connection, or redials
    /// when the connection itself has positive evidence of silence.
    ///
    /// Outcomes, in order of evidence strength:
    /// - The host's application layer acknowledged a fresh stream: stranded
    ///   requests are resent or failed, then a probe verifies the replacement
    ///   actually serves requests. An unanswered probe escalates to redial, so
    ///   replacement never loops.
    /// - The whole connection is positively silent: redial now, one deadline
    ///   sooner than the conservative threshold.
    /// - Anything else: keep the conservative two-silent-timeout threshold.
    func repairSilentControlStream(
        connectionID: UUID,
        silentSince: ContinuousClock.Instant,
        verificationTimeoutNanoseconds: UInt64
    ) async {
        // The caller claimed `controlStreamRepairInFlight` synchronously so a
        // concurrent silent timeout cannot start a second replacement.
        defer { controlStreamRepairInFlight = false }
        guard installedConnectionID == connectionID,
              !isTearingDown,
              let repairing = transport as? any CmxByteTransportControlStreamRepairing else {
            return
        }
        unverifiedControlStreamRepairs += 1
        let outcome = await repairing.repairControlStream(silentSince: silentSince)
        guard installedConnectionID == connectionID, !isTearingDown else { return }
        switch outcome {
        case .unavailable:
            return
        case .connectionSilent:
            await tearDown(error: .connectionClosed)
        case let .repaired(generation):
            repairedControlStreamGeneration = max(repairedControlStreamGeneration, generation)
            resolveControlFramesStranded(before: generation)
            let answered = await verifyReplacedControlStream(
                timeoutNanoseconds: verificationTimeoutNanoseconds
            )
            guard installedConnectionID == connectionID, !isTearingDown else { return }
            if answered {
                unverifiedControlStreamRepairs = 0
                silentTimeoutStreak = 0
            } else {
                await tearDown(error: .connectionClosed)
            }
        }
    }

    /// Requests written to a replaced stream may never have reached the host,
    /// or may have reached it with the answer lost. Read-only requests are
    /// resent in their original order. Anything else may already have been
    /// applied, so it fails back as a timeout (outcome unknown) instead of
    /// risking a second application.
    private func resolveControlFramesStranded(before generation: UInt64) {
        let stranded = writtenControlFrames
            .filter { $0.value.generation < generation }
            .sorted { $0.value.sequence < $1.value.sequence }
        for (requestID, written) in stranded {
            writtenControlFrames.removeValue(forKey: requestID)
            guard isAwaitingResponse(requestID) else { continue }
            guard MobileRPCControlFrameResendPolicy.allowsResend(ofFrame: written.frame),
                  let queue = writeQueue else {
                failPending(requestID: requestID, error: .requestTimedOut)
                continue
            }
            let queuedWriteID = UUID()
            queuedWriteIDs[requestID] = queuedWriteID
            _ = queue.yield(PendingWrite(
                id: queuedWriteID,
                requestID: requestID,
                frame: written.frame
            ))
        }
    }

    /// Sends a read-only probe on the replacement stream and waits for any
    /// host answer. A host RPC error is still an answer from the host's RPC
    /// layer, which is what this verifies.
    private func verifyReplacedControlStream(timeoutNanoseconds: UInt64) async -> Bool {
        let probeID = "cmux.control-stream-probe.\(UUID().uuidString)"
        let request: [String: Any] = [
            "id": probeID,
            "method": MobileRPCControlFrameResendPolicy.verificationProbeMethod,
            "params": ["stream_id": probeID],
        ]
        guard timeoutNanoseconds > 0,
              let payload = try? JSONSerialization.data(withJSONObject: request),
              let frame = try? MobileSyncFrameCodec.encodeFrame(payload),
              let queue = writeQueue else {
            return false
        }
        let queuedWriteID = UUID()
        pipelinedPending[probeID] = .pending
        queuedWriteIDs[probeID] = queuedWriteID
        _ = queue.yield(PendingWrite(id: queuedWriteID, requestID: probeID, frame: frame))
        let deadline = Task { [weak self, taskTimeout] in
            do {
                try await taskTimeout.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            await self?.expireControlStreamProbe(requestID: probeID)
        }
        defer { deadline.cancel() }
        do {
            _ = try await awaitResponse(requestID: probeID)
            return true
        } catch let error as MobileShellConnectionError {
            switch error {
            case .rpcError, .authorizationFailed, .accountMismatch:
                return true
            default:
                return false
            }
        } catch {
            return false
        }
    }

    private func expireControlStreamProbe(requestID: String) {
        guard isAwaitingResponse(requestID) else { return }
        if let queuedWriteID = queuedWriteIDs.removeValue(forKey: requestID) {
            cancelledQueuedWriteIDs.insert(queuedWriteID)
        }
        failPending(requestID: requestID, error: .requestTimedOut)
    }
}
