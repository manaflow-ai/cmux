import CMUXMobileCore
import Foundation

// MobileCoreRPCSession's pending requests: cancellation, response timeouts, and settling a
// request exactly once.
extension MobileCoreRPCSession {
    func failPending(requestID: String, error: MobileShellConnectionError) {
        settlePendingRequest(
            requestID: requestID,
            settlement: .response(.failure(error))
        )
    }
    func cancelPendingRequest(requestID: String) async {
        let legacyContinuation = pending.removeValue(forKey: requestID)
        let pipelinedSettlement = pipelinedPending.removeValue(
            forKey: requestID
        )
        let pipelinedContinuation: PendingContinuation?
        if case let .awaiting(continuation) = pipelinedSettlement {
            pipelinedContinuation = continuation
        } else {
            pipelinedContinuation = nil
        }
        guard legacyContinuation != nil || pipelinedSettlement != nil else {
            return
        }
        requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        writtenControlFrames.removeValue(forKey: requestID)
        if let queuedWriteID = queuedWriteIDs.removeValue(forKey: requestID) {
            cancelledQueuedWriteIDs.insert(queuedWriteID)
        }
        startCancelledActiveWriteResolution(requestID: requestID)
        legacyContinuation?.resume(returning: .cancelled)
        pipelinedContinuation?.resume(returning: .cancelled)
    }

    private func timeoutPendingRequest(
        requestID: String,
        armedConnectionID: UUID? = nil,
        armedInboundCount: UInt64 = 0,
        armedSilentEpoch: UInt64 = 0,
        armedAt: ContinuousClock.Instant = .now,
        armedTimeoutNanoseconds: UInt64 = 0
    ) async {
        let legacyContinuation = pending.removeValue(forKey: requestID)
        let pipelinedSettlement = pipelinedPending.removeValue(
            forKey: requestID
        )
        guard legacyContinuation != nil || pipelinedSettlement != nil else {
            return
        }
        requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        writtenControlFrames.removeValue(forKey: requestID)
        // A request still sitting in the write queue never reached the wire,
        // so its expiry says nothing about whether the transport can deliver.
        // It means the queue is backed up, which the head-of-line handling
        // below already owns.
        let reachedTheWire = queuedWriteIDs[requestID] == nil
        var condemnedWriteRequestID = requestID
        if let queuedWriteID = queuedWriteIDs.removeValue(forKey: requestID) {
            cancelledQueuedWriteIDs.insert(queuedWriteID)
            // A queued request dying head-of-line blocked behind a cancelled
            // unresolved write is unserved demand: condemn that write now.
            // Its timeout must not merely erase it from `queuedWriteIDs`,
            // where the grace watchdog would mistake it for an explicit
            // cancellation and preserve the wedged transport.
            if let write = activeWrite,
               write.cancelledRequestResolutionTask != nil {
                condemnedWriteRequestID = write.requestID
            }
        }
        var error: MobileShellConnectionError = if await recycleTransportIfActiveWrite(
            requestID: condemnedWriteRequestID
        ) {
            .transportWriteTimedOut
        } else {
            .requestTimedOut
        }
        // `recycleTransportIfActiveWrite` only condemns a transport whose
        // *write* is stuck and that already reports itself closed. A path that
        // black-holes after the write succeeded satisfies neither, so without
        // this the dead transport stays installed and `ensureConnected` hands
        // it to the retry, which burns another full deadline. Two of those is
        // a minute of blank terminal.
        var repairsSilentControlStream = false
        if case .requestTimedOut = error, reachedTheWire {
            if transportDeliveredNothing(
                armedConnectionID: armedConnectionID,
                armedInboundCount: armedInboundCount
            ) {
                // Requests armed before the last counted timeout share its
                // silence window; they are already represented by it. A
                // replacement in flight owns the current silence window, and
                // its own verification decides whether to escalate.
                if armedSilentEpoch == silentTimeoutEpoch,
                   !controlStreamRepairInFlight {
                    silentTimeoutEpoch &+= 1
                    silentTimeoutStreak += 1
                    if silentTimeoutStreak >= Self.minimumSilentTimeoutsBeforeCondemning {
                        error = .connectionClosed
                        await tearDown(error: .connectionClosed)
                    } else if transport is any CmxByteTransportControlStreamRepairing,
                              unverifiedControlStreamRepairs
                                < Self.maximumUnverifiedControlStreamRepairs {
                        // One silent stream is ambiguous about the connection
                        // but not about the stream. Ask the connection for
                        // evidence now instead of burning a second deadline.
                        repairsSilentControlStream = true
                    }
                }
            } else {
                silentTimeoutStreak = 0
            }
        }
        let settlement = PendingRequestSettlement.response(.failure(error))
        legacyContinuation?.resume(returning: settlement)
        switch pipelinedSettlement {
        case .pending:
            pipelinedPending[requestID] = .settled(settlement)
        case let .awaiting(continuation):
            continuation.resume(returning: settlement)
        case .settled, nil:
            break
        }
        // Fail this caller first: replacement and its verification can take
        // a round trip or two, and this request's deadline already passed.
        // The repair runs in its own task because this one is the request's
        // timeout task, which the settlement above has already cancelled.
        if repairsSilentControlStream, let armedConnectionID {
            controlStreamRepairInFlight = true
            let verificationTimeoutNanoseconds = min(
                armedTimeoutNanoseconds,
                Self.maximumControlStreamRepairVerificationNanoseconds
            )
            Task { [weak self] in
                await self?.repairSilentControlStream(
                    connectionID: armedConnectionID,
                    silentSince: armedAt,
                    verificationTimeoutNanoseconds: verificationTimeoutNanoseconds
                )
            }
        }
    }

    func shouldSendQueuedWrite(_ write: PendingWrite) -> Bool {
        if cancelledQueuedWriteIDs.remove(write.id) != nil {
            return false
        }
        guard queuedWriteIDs[write.requestID] == write.id else {
            return false
        }
        queuedWriteIDs[write.requestID] = nil
        let hasPipelinedRequestAwaitingResponse: Bool
        switch pipelinedPending[write.requestID] {
        case .pending, .awaiting:
            hasPipelinedRequestAwaitingResponse = true
        case .settled, nil:
            hasPipelinedRequestAwaitingResponse = false
        }
        return pending[write.requestID] != nil
            || hasPipelinedRequestAwaitingResponse
    }

    func armResponseTimeout(
        requestID: String,
        timeoutNanoseconds: UInt64
    ) {
        requestTimeoutTasks[requestID]?.cancel()
        let armedConnectionID = installedConnectionID
        let armedInboundCount = inboundDeliveryCount
        let armedSilentEpoch = silentTimeoutEpoch
        let armedAt = ContinuousClock.now
        requestTimeoutTasks[requestID] = Task { [weak self, taskTimeout] in
            do {
                try await taskTimeout.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            guard let self else { return }
            await self.timeoutPendingRequest(
                requestID: requestID,
                armedConnectionID: armedConnectionID,
                armedInboundCount: armedInboundCount,
                armedSilentEpoch: armedSilentEpoch,
                armedAt: armedAt,
                armedTimeoutNanoseconds: timeoutNanoseconds
            )
        }
    }

    /// Whether a timed-out request proves its transport can no longer deliver.
    ///
    /// Only a transport that delivered *nothing* for the whole life of the
    /// request is condemned. If anything arrived (another response, an event
    /// frame, a terminal delta) the lane is demonstrably alive and this one
    /// request was merely slow, so the request fails alone. Requires the same
    /// installed connection throughout: a timeout belonging to a connection
    /// that has already been replaced says nothing about the current one.
    private func transportDeliveredNothing(
        armedConnectionID: UUID?,
        armedInboundCount: UInt64
    ) -> Bool {
        guard let armedConnectionID,
              installedConnectionID == armedConnectionID else { return false }
        return inboundDeliveryCount == armedInboundCount
    }

    func settlePendingRequest(
        requestID: String,
        settlement: PendingRequestSettlement
    ) {
        writtenControlFrames.removeValue(forKey: requestID)
        if let continuation = pending.removeValue(forKey: requestID) {
            requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
            continuation.resume(returning: settlement)
            return
        }
        switch pipelinedPending[requestID] {
        case .pending:
            requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
            pipelinedPending[requestID] = .settled(settlement)
        case let .awaiting(continuation):
            requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
            pipelinedPending.removeValue(forKey: requestID)
            continuation.resume(returning: settlement)
        case .settled, nil:
            break
        }
    }
}
