import CMUXMobileCore
import Foundation

// MobileCoreRPCSession's connect path: one shared connect per session, its waiters, timeouts
// and cancellations.
extension MobileCoreRPCSession {
    // MARK: - private

    func ensureConnected(timeoutNanoseconds: UInt64) async throws -> any CmxByteTransport {
        // `tearDown` is actor-reentrant while it awaits transport close and
        // abandoned-connect cleanup. Reject requests that arrive in that
        // window so a stale client cannot install a replacement transport
        // underneath the shell owner that is retiring it.
        guard !isTearingDown else {
            throw MobileShellConnectionError.connectionClosed
        }
        if let transport { return transport }
        // A cancellation-ignoring connect or close still owns this client's
        // production route until cleanup closes it or transfers its late
        // watcher to the shared route registry. Do not let repeated requests
        // append more retained cleanup graphs before that bounded handoff.
        // Direct untracked sessions have no shared route authority and retain
        // their cooperative-cancellation retry semantics.
        if connectAttemptKey != nil,
           !abandonedConnectionCleanupTasks.isEmpty {
            throw MobileShellConnectionError.routeCleanupBlocked
        }
        let waiterID = UUID()
        let connectionID: UUID
        let connectLease: MobileRPCConnectAttemptLease?
        let task: Task<any CmxByteTransport, any Error>
        let cancellationClose: MobileRPCConnectCancellationClose
        if let existing = connectionTask {
            connectionID = existing.id
            connectLease = existing.lease
            task = existing.task
            cancellationClose = existing.cancellationClose
            connectionTask?.waiters.insert(waiterID)
        } else {
            switch await connectAttemptRegistry.beginConnect(
                key: connectAttemptKey
            ) {
            case .granted(let lease):
                connectLease = lease
            case .busy:
                // A gate refusal is instantaneous and never touched the
                // network; reporting it as a timeout fabricated sub-30ms
                // "timedOut" failures that poisoned lastFailureEvent.
                throw MobileShellConnectionError.connectAttemptGated
            case .cleanupBlocked:
                throw MobileShellConnectionError.routeCleanupBlocked
            }
            let connectAttemptID = Int.random(in: 1...Int.max)
            let connectStartedAt = ContinuousClock.now
            let diagnosticTransport = diagnosticTransport
            let transportConnectObserver = transportConnectObserver
            let initialSessionPurpose = transportSessionPurpose
            let reportCancelledConnect: @Sendable () -> Void = {
                if let diagnosticTransport, let transportConnectObserver {
                    transportConnectObserver(
                        .failed(
                            attemptID: connectAttemptID,
                            transport: diagnosticTransport,
                            failure: .cancelled,
                            elapsedMilliseconds: Self.elapsedMilliseconds(
                                since: connectStartedAt
                            )
                        )
                    )
                }
            }
            if let diagnosticTransport, let transportConnectObserver {
                transportConnectObserver(
                    .attempt(
                        attemptID: connectAttemptID,
                        transport: diagnosticTransport
                    )
                )
            }
            let candidate: any CmxByteTransport
            do {
                candidate = try makeTransport()
            } catch let rejected as MobileRPCRejectedTransportDisposal {
                await connectAttemptRegistry.handOffPhysicalCleanup(
                    lease: connectLease
                ) {
                    await rejected.task.value
                }
                if Task.isCancelled {
                    reportCancelledConnect()
                    throw CancellationError()
                }
                let error = MobileShellConnectionError.connectionClosed
                if let diagnosticTransport,
                   let transportConnectObserver {
                    transportConnectObserver(
                        .failed(
                            attemptID: connectAttemptID,
                            transport: diagnosticTransport,
                            failure: DiagnosticFailureKind.classify(error),
                            elapsedMilliseconds: Self.elapsedMilliseconds(
                                since: connectStartedAt
                            )
                        )
                    )
                }
                throw error
            } catch {
                await connectAttemptRegistry.finishConnect(lease: connectLease)
                if error is CancellationError || Task.isCancelled {
                    reportCancelledConnect()
                    throw CancellationError()
                }
                if let diagnosticTransport, let transportConnectObserver {
                    transportConnectObserver(
                        .failed(
                            attemptID: connectAttemptID,
                            transport: diagnosticTransport,
                            failure: DiagnosticFailureKind.classify(error),
                            elapsedMilliseconds: Self.elapsedMilliseconds(
                                since: connectStartedAt
                            )
                        )
                    )
                }
                throw error
            }
            connectionID = UUID()
            cancellationClose =
                MobileRPCConnectCancellationClose()
            task = Task.detached {
                do {
                    if let initialSessionPurpose,
                       let updating =
                        candidate as? any CmxByteTransportSessionPurposeUpdating {
                        await updating.updateSessionPurpose(
                            initialSessionPurpose
                        )
                    }
                    try await withTaskCancellationHandler {
                        try await candidate.connect()
                    } onCancel: {
                        Task.detached {
                            await cancellationClose.start(candidate)
                        }
                    }
                    if Task.isCancelled {
                        _ = await cancellationClose.task()
                    } else {
                        await cancellationClose.finishWithoutClose()
                    }
                    // A cancellation-ignoring transport must still return its
                    // late candidate to the existing abandoned-connect cleanup
                    // path so that path can close it again after completion.
                    // Report the abandoned attempt as cancelled without
                    // replacing that result with `CancellationError`.
                    if Task.isCancelled {
                        reportCancelledConnect()
                    } else if let diagnosticTransport,
                              let transportConnectObserver {
                        transportConnectObserver(
                            .connected(
                                attemptID: connectAttemptID,
                                transport: diagnosticTransport,
                                elapsedMilliseconds:
                                    Self.elapsedMilliseconds(since: connectStartedAt),
                                sessionID: await (
                                    candidate as? any CmxByteTransportDiagnosticSessionIdentifying
                                )?.transportDiagnosticSessionID()
                            )
                        )
                    }
                    return candidate
                } catch is CancellationError {
                    if Task.isCancelled {
                        _ = await cancellationClose.task()
                    } else {
                        await cancellationClose.finishWithoutClose()
                    }
                    reportCancelledConnect()
                    throw CancellationError()
                } catch {
                    // Some transports surface their close error instead of
                    // `CancellationError` after the cancellation handler closes
                    // them. Treat the task's cancellation bit as authoritative
                    // so an abandoned dial reports cancelled, never a false
                    // transport failure.
                    if Task.isCancelled {
                        _ = await cancellationClose.task()
                        reportCancelledConnect()
                        throw CancellationError()
                    }
                    await cancellationClose.finishWithoutClose()
                    if let diagnosticTransport, let transportConnectObserver {
                        transportConnectObserver(
                            .failed(
                                attemptID: connectAttemptID,
                                transport: diagnosticTransport,
                                failure: DiagnosticFailureKind.classify(error),
                                elapsedMilliseconds: Self.elapsedMilliseconds(
                                    since: connectStartedAt
                                )
                            )
                        )
                    }
                    throw error
                }
            }
            connectionTask = (
                id: connectionID,
                lease: connectLease,
                task: task,
                cancellationClose: cancellationClose,
                diagnosticAttemptID: connectAttemptID,
                diagnosticStartedAt: connectStartedAt,
                waiters: [waiterID],
                completed: false
            )
            Task.detached { [weak self] in
                _ = await task.result
                await self?.markConnectingCompleted(id: connectionID)
            }
        }

        let candidate: any CmxByteTransport
        let callerCancelled: Bool
        do {
            let connected = try await taskTimeout.value(task, timeoutNanoseconds: timeoutNanoseconds)
            if let didReceiveConnectedCandidate {
                await didReceiveConnectedCandidate(connected)
            }
            await Task.yield()
            callerCancelled = Task.isCancelled
            candidate = connected
        } catch {
            if Task.isCancelled {
                await cancelConnectingWaiter(id: connectionID, waiterID: waiterID)
                throw CancellationError()
            }
            if case MobileShellConnectionError.requestTimedOut = error {
                await timeoutConnectingWaiter(id: connectionID, waiterID: waiterID)
            } else if error is CancellationError {
                if connectionTask?.id == connectionID {
                    connectionTask = nil
                    await connectAttemptRegistry.finishConnect(lease: connectLease)
                }
            } else if connectionTask?.id == connectionID {
                connectionTask = nil
                await connectAttemptRegistry.finishConnect(lease: connectLease)
            }
            throw error
        }

        if let transport {
            if installedConnectionID != connectionID {
                closeUninstalledConnectedCandidate(candidate, lease: connectLease)
            }
            if callerCancelled {
                throw CancellationError()
            }
            return transport
        }

        guard connectionTask?.id == connectionID else {
            closeUninstalledConnectedCandidate(candidate, lease: connectLease)
            throw MobileShellConnectionError.connectionClosed
        }

        if let updating =
            candidate as? any CmxByteTransportSessionPurposeUpdating {
            var appliedPurpose: CmxTransportSessionPurpose?
            while let currentSessionPurpose = transportSessionPurpose,
                  currentSessionPurpose != appliedPurpose {
                await updating.updateSessionPurpose(currentSessionPurpose)
                appliedPurpose = currentSessionPurpose
                // Another waiter for this same connection may have installed
                // the shared candidate while this actor was suspended in the
                // transport update. Reuse that installed generation instead of
                // treating the candidate as stale and closing the live session.
                if let installedTransport = transport {
                    guard installedConnectionID == connectionID else {
                        closeUninstalledConnectedCandidate(
                            candidate,
                            lease: connectLease
                        )
                        throw MobileShellConnectionError.connectionClosed
                    }
                    if callerCancelled || Task.isCancelled {
                        throw CancellationError()
                    }
                    return installedTransport
                }
                guard connectionTask?.id == connectionID,
                      !isTearingDown else {
                    closeUninstalledConnectedCandidate(
                        candidate,
                        lease: connectLease
                    )
                    throw MobileShellConnectionError.connectionClosed
                }
            }
        }

        if callerCancelled {
            connectionTask?.waiters.remove(waiterID)
        }

        if callerCancelled, connectionTask?.waiters.isEmpty == true {
            connectionTask = nil
            closeUninstalledConnectedCandidate(candidate, lease: connectLease)
            throw CancellationError()
        }

        let (stream, continuation) = AsyncStream<PendingWrite>.makeStream(
            bufferingPolicy: .unbounded
        )
        let nextReaderTask = Task { [weak self] in
            guard let self else { return }
            await self.readLoop(
                transport: candidate,
                connectionID: connectionID
            )
        }
        let nextWriterTask = Task { [weak self] in
            guard let self else { return }
            await self.writeLoop(
                transport: candidate,
                connectionID: connectionID,
                frames: stream
            )
        }
        let nextTransportClosureTask = Task { [weak self] in
            var waitedForClosureReadiness = false
            while !Task.isCancelled {
                if let observation = await (
                    candidate as? any CmxByteTransportClosureObserving
                )?.transportClosureObservation() {
                    await observation.waitUntilClosed()
                    guard !Task.isCancelled else { return }
                    await self?.transportDidClose(connectionID: connectionID)
                    return
                }
                guard let readiness = candidate as?
                    any CmxByteTransportClosureObservationReadiness else {
                    return
                }
                // Allow exactly one activation transition. If an activated
                // transport still cannot produce an observation, terminate
                // this generation instead of actor-hopping forever.
                guard !waitedForClosureReadiness else { return }
                waitedForClosureReadiness = true
                // Deferred transports signal activation once. This avoids a
                // permanent 100 ms polling task for transports that never
                // expose native closure observation.
                guard await readiness.waitUntilTransportClosureObservationIsReady() else {
                    return
                }
            }
        }

        // Publish one coherent installed generation without suspending. Readers
        // use `transport` as the fast-path readiness flag, so it must become
        // visible only after its reader and writer infrastructure is installed.
        connectionTask = nil
        installedConnectionID = connectionID
        readerTask = nextReaderTask
        writeQueue = continuation
        writerTask = nextWriterTask
        transportClosureTask = nextTransportClosureTask
        transport = candidate
        installedConnectLease = connectLease

        guard installedConnectionID == connectionID,
              transport != nil,
              !isTearingDown else {
            throw MobileShellConnectionError.connectionClosed
        }
        if callerCancelled || Task.isCancelled {
            throw CancellationError()
        }
        return candidate
    }

    nonisolated static func elapsedMilliseconds(
        since start: ContinuousClock.Instant
    ) -> Int {
        let components = start.duration(to: .now).components
        let milliseconds = components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
        return max(0, Int(milliseconds))
    }

    private func cancelConnectingWaiter(id connectionID: UUID, waiterID: UUID) async {
        guard transport == nil,
              let connecting = connectionTask,
              connecting.id == connectionID else {
            return
        }
        connectionTask?.waiters.remove(waiterID)
        guard connectionTask?.waiters.isEmpty == true else { return }
        if connecting.completed {
            connectionTask = nil
            startAbandonedConnectionCleanup(
                task: connecting.task,
                lease: connecting.lease,
                cancellationClose: connecting.cancellationClose,
                cleanupTimeoutNanoseconds: abandonedConnectCleanupTimeoutNanoseconds,
                lateCloseTimeoutNanoseconds: lateAbandonedConnectCloseTimeoutNanoseconds
            )
            return
        }
        connectionTask = nil
        recordConnectCancellation(connecting, reason: .requestCancelled)
        connecting.task.cancel()
        startAbandonedConnectionCleanup(
            task: connecting.task,
            lease: connecting.lease,
            cancellationClose: connecting.cancellationClose,
            cleanupTimeoutNanoseconds: abandonedConnectCleanupTimeoutNanoseconds,
            lateCloseTimeoutNanoseconds: lateAbandonedConnectCloseTimeoutNanoseconds
        )
    }
    private func timeoutConnectingWaiter(id connectionID: UUID, waiterID: UUID) async {
        guard transport == nil,
              let connecting = connectionTask,
              connecting.id == connectionID else {
            return
        }
        connectionTask?.waiters.remove(waiterID)
        guard connectionTask?.waiters.isEmpty == true else { return }
        if connecting.completed {
            connectionTask = nil
            startAbandonedConnectionCleanup(
                task: connecting.task,
                lease: connecting.lease,
                cancellationClose: connecting.cancellationClose,
                cleanupTimeoutNanoseconds: abandonedConnectCleanupTimeoutNanoseconds,
                lateCloseTimeoutNanoseconds: lateAbandonedConnectCloseTimeoutNanoseconds
            )
            return
        }
        connectionTask = nil
        recordConnectCancellation(connecting, reason: .requestTimedOut)
        connecting.task.cancel()
        startAbandonedConnectionCleanup(
            task: connecting.task,
            lease: connecting.lease,
            cancellationClose: connecting.cancellationClose,
            cleanupTimeoutNanoseconds: abandonedConnectCleanupTimeoutNanoseconds,
            lateCloseTimeoutNanoseconds: lateAbandonedConnectCloseTimeoutNanoseconds
        )
    }

    private func markConnectingCompleted(id connectionID: UUID) {
        guard connectionTask?.id == connectionID else { return }
        if let current = connectionTask {
            connectionTask = (
                id: current.id,
                lease: current.lease,
                task: current.task,
                cancellationClose: current.cancellationClose,
                diagnosticAttemptID: current.diagnosticAttemptID,
                diagnosticStartedAt: current.diagnosticStartedAt,
                waiters: current.waiters,
                completed: true
            )
        }
    }

    func recordConnectCancellation(
        _ connecting: ConnectingTask,
        reason: DiagnosticCancellationReason
    ) {
        guard let attemptID = connecting.diagnosticAttemptID,
              let diagnosticTransport,
              let transportConnectObserver,
              recordedConnectCancellationAttemptIDs.insert(attemptID).inserted
        else { return }
        transportConnectObserver(.cancelled(
            attemptID: attemptID,
            transport: diagnosticTransport,
            reason: reason,
            elapsedMilliseconds: Self.elapsedMilliseconds(
                since: connecting.diagnosticStartedAt ?? ContinuousClock.now
            )
        ))
    }
}
