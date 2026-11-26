import Foundation

// MobileCoreRPCSession's teardown: failing pending requests, closing the transport, and
// waiting for the transport to drain.
extension MobileCoreRPCSession {
    func tearDown(error: MobileShellConnectionError) async {
        if isTearingDown {
            await withCheckedContinuation {
                tearDownWaiters.append($0)
            }
            return
        }
        isTearingDown = true
        // Evidence is per connection. A replacement transport must not
        // inherit a streak accumulated against the one it replaces, or its
        // first silent timeout condemns it on a single piece of evidence.
        silentTimeoutStreak = 0
        // The replacement budget and stranded-frame ledger are per connection
        // too; the redial gets a fresh control stream and fresh budget.
        unverifiedControlStreamRepairs = 0
        writtenControlFrames.removeAll()
        repairedControlStreamGeneration = 0
        defer {
            isTearingDown = false
            let waiters = tearDownWaiters
            tearDownWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
        let pendingSnapshot = pending
        pending.removeAll()
        let pipelinedSnapshot = pipelinedPending
        pipelinedPending.removeAll()
        let timeoutSnapshot = requestTimeoutTasks
        requestTimeoutTasks.removeAll()
        queuedWriteIDs.removeAll()
        cancelledQueuedWriteIDs.removeAll()
        for (_, task) in timeoutSnapshot {
            task.cancel()
        }
        for (_, cont) in pendingSnapshot {
            cont.resume(returning: .response(.failure(error)))
        }
        for (requestID, settlement) in pipelinedSnapshot {
            switch settlement {
            case let .awaiting(continuation):
                continuation.resume(returning: .response(.failure(error)))
            case .pending:
                // Preserve the real teardown failure for a handle nobody has
                // awaited yet; dropping it would misreport the outcome as a
                // protocol error (invalidResponse) when response() is called.
                pipelinedPending[requestID] = .settled(.response(.failure(error)))
            case .settled:
                // Keep an already-settled outcome claimable; entries are
                // bounded by the caller's pipeline window and are removed on
                // claim or abandon.
                pipelinedPending[requestID] = settlement
            }
        }
        let listenerSnapshot = listeners
        listeners.removeAll()
        for (_, listener) in listenerSnapshot {
            listener.continuation.finish()
        }
        writeQueue?.finish()
        writeQueue = nil
        activeWrite?.task.cancel()
        activeWrite?.cancelledRequestResolutionTask?.cancel()
        activeWrite = nil
        resumeWriteResolutionWaiters()
        writerTask?.cancel()
        writerTask = nil
        let connecting = connectionTask
        if let connecting {
            recordConnectCancellation(connecting, reason: .sessionTeardown)
        }
        connecting?.task.cancel()
        connectionTask = nil
        installedConnectionID = nil
        let installedLease = installedConnectLease
        installedConnectLease = nil
        let transportToClose = transport
        transport = nil
        readerTask?.cancel()
        readerTask = nil
        transportClosureTask?.cancel()
        transportClosureTask = nil
        independentEventPreparation?.task.cancel()
        independentEventPreparation = nil
        independentEventReader?.task.cancel()
        independentEventReader = nil
        independentEventSubscriptionStreamIDs.removeAll()
        await tearDownRegistrationHook?()
        if let transportToClose {
            await enqueueTransportClose(
                transportToClose,
                lease: installedLease
            )
        } else {
            await connectAttemptRegistry.finishConnect(
                lease: installedLease
            )
        }
        if let connecting { await abandonConnectionTask(connecting) }
    }

    /// Wait until every installed transport detached by teardown has completed
    /// `close()` and every abandoned dial has either closed or transferred its
    /// late cleanup to the shared route registry. Ordinary reconnects do not
    /// block on this bounded drain, but a same-peer ownership handoff observes
    /// it before redialing.
    func waitForTransportDrain() async {
        while !transportCloseTasks.isEmpty
            || !abandonedConnectionCleanupTasks.isEmpty {
            let installedTransportCloses =
                Array(transportCloseTasks.values)
            let abandonedConnectCleanups =
                Array(abandonedConnectionCleanupTasks.values)
            for close in installedTransportCloses {
                await close.value
            }
            for cleanup in abandonedConnectCleanups {
                await cleanup.value
            }
        }
    }
}
