import CMUXMobileCore
import Foundation

// MobileCoreRPCSession's cancelled writes: resolving a write cancelled mid-flight, and
// recovering queued demand behind it.
extension MobileCoreRPCSession {
    func clearActiveWrite(connectionID: UUID, requestID: String) {
        guard activeWrite?.connectionID == connectionID,
              activeWrite?.requestID == requestID else { return }
        activeWrite = nil
        // Resume coalesced waiters only on a real transition of the CURRENT
        // write: a stale completion callback from an older write generation
        // must not satisfy the recovery gate or the queued-demand watchdog
        // for a newer cancelled write.
        resumeWriteResolutionWaiters()
    }

    func startCancelledActiveWriteResolution(requestID: String) {
        guard var write = activeWrite,
              write.requestID == requestID,
              write.cancelledRequestResolutionTask == nil else { return }
        let connectionID = write.connectionID
        let sendTask = write.task
        let resolutionTask = Task { [weak self] in
            do {
                _ = try await sendTask.value
                await self?.cancelledActiveWriteDidComplete(
                    connectionID: connectionID,
                    requestID: requestID
                )
            } catch {
                await self?.cancelledActiveWriteDidFail(
                    connectionID: connectionID,
                    requestID: requestID
                )
            }
        }
        write.cancelledRequestResolutionTask = resolutionTask
        activeWrite = write
        startQueuedDemandRecovery(requestID: requestID)
    }

    /// Requests already queued behind the cancelled write have passed the
    /// `send()` recovery gate, so without this watchdog a stalled cancelled
    /// write would block them until their own deadlines and even then leave
    /// the wedged transport installed (their timeout cannot recycle a write
    /// owned by another request ID).
    private func startQueuedDemandRecovery(requestID: String) {
        // Native connection observation owns Iroh's lifetime. Queued demand
        // has its own request deadline and cannot condemn an unfinished frame.
        guard !(transport is any CmxByteTransportLivenessObserving),
              !queuedWriteIDs.isEmpty else { return }
        Task { [self, taskTimeout, cancelledWriteCompletionGraceNanoseconds] in
            let waitTask = Task<Void, any Error> {
                await self.awaitCancelledWriteResolution()
            }
            do {
                try await taskTimeout.value(
                    waitTask,
                    timeoutNanoseconds: cancelledWriteCompletionGraceNanoseconds
                )
            } catch {
                waitTask.cancel()
                await self.recycleCancelledActiveWriteForQueuedDemand(
                    requestID: requestID
                )
            }
        }
    }

    private func recycleCancelledActiveWriteForQueuedDemand(
        requestID: String
    ) async {
        // Re-check demand at grace expiry: if every queued request was
        // cancelled meanwhile, preserve the transport like the no-demand path.
        guard !queuedWriteIDs.isEmpty else { return }
        _ = await recycleTransportIfActiveWrite(requestID: requestID)
    }

    func waitForCancelledActiveWriteResolution(
        deadlineUptimeNanoseconds: UInt64
    ) async throws {
        // Preserve serialization until the native write completes or fails.
        // Cancelling writeAll can leave a frame prefix on the control stream.
        // Later requests may queue and expire without cancelling that write.
        if transport is any CmxByteTransportLivenessObserving { return }
        while let write = activeWrite,
              write.cancelledRequestResolutionTask != nil {
            try Task.checkCancellation()
            let remainingNanoseconds: UInt64
            do {
                remainingNanoseconds = try taskTimeout.remainingNanoseconds(
                    until: deadlineUptimeNanoseconds
                )
            } catch MobileShellConnectionError.requestTimedOut {
                _ = await recycleTransportIfActiveWrite(
                    requestID: write.requestID
                )
                throw MobileShellConnectionError.requestTimedOut
            }
            let waitTask = Task<Void, any Error> {
                await self.awaitCancelledWriteResolution()
            }
            do {
                try await taskTimeout.value(
                    waitTask,
                    timeoutNanoseconds: min(
                        remainingNanoseconds,
                        cancelledWriteCompletionGraceNanoseconds
                    )
                )
            } catch is CancellationError {
                waitTask.cancel()
                throw CancellationError()
            } catch MobileShellConnectionError.requestTimedOut {
                waitTask.cancel()
                let deadlineExpired =
                    (try? taskTimeout.remainingNanoseconds(
                        until: deadlineUptimeNanoseconds
                    )) == nil
                _ = await recycleTransportIfActiveWrite(
                    requestID: write.requestID
                )
                if deadlineExpired {
                    throw MobileShellConnectionError.requestTimedOut
                }
            }
        }
        try Task.checkCancellation()
    }

    /// Suspends until the cancelled active write completes, fails, or is
    /// recycled. Waiters are coalesced on this actor and resumed by those
    /// resolution events — or unregistered by their own cancellation — so an
    /// abandoned wait never strands a task or continuation parked on the
    /// stalled send itself.
    private func awaitCancelledWriteResolution() async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard activeWrite?.cancelledRequestResolutionTask != nil,
                      !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                writeResolutionWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.cancelWriteResolutionWaiter(waiterID) }
        }
    }

    private func cancelWriteResolutionWaiter(_ waiterID: UUID) {
        writeResolutionWaiters.removeValue(forKey: waiterID)?.resume()
    }

    func resumeWriteResolutionWaiters() {
        guard !writeResolutionWaiters.isEmpty else { return }
        let waiters = writeResolutionWaiters
        writeResolutionWaiters.removeAll()
        for continuation in waiters.values {
            continuation.resume()
        }
    }

    private func cancelledActiveWriteDidComplete(
        connectionID: UUID,
        requestID: String
    ) {
        clearActiveWrite(connectionID: connectionID, requestID: requestID)
    }

    private func cancelledActiveWriteDidFail(
        connectionID: UUID,
        requestID: String
    ) async {
        guard activeWrite?.connectionID == connectionID,
              activeWrite?.requestID == requestID else { return }
        activeWrite = nil
        resumeWriteResolutionWaiters()
        await tearDownIfInstalled(
            connectionID: connectionID,
            error: .connectionClosed
        )
    }

    func recycleTransportIfActiveWrite(requestID: String) async -> Bool {
        guard let write = activeWrite, write.requestID == requestID else { return false }
        if let observing = transport as? any CmxByteTransportLivenessObserving {
            guard await observing.isTransportClosed() else { return false }
            guard activeWrite?.connectionID == write.connectionID,
                  activeWrite?.requestID == requestID else { return false }
        }
        activeWrite?.task.cancel()
        activeWrite?.cancelledRequestResolutionTask?.cancel()
        activeWrite = nil
        resumeWriteResolutionWaiters()
        await tearDown(error: .connectionClosed)
        return true
    }
}
