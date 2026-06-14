internal import Darwin
internal import Foundation

extension SocketControlServer {
    /// Arms the accept read source for `listenerSocket` under `generation`.
    ///
    /// `DispatchSource.makeReadSource` carve-out: low-level socket I/O event
    /// delivery with no async-native equivalent. The handlers are state-free:
    /// the event handler drains accepts against the published snapshot, and
    /// the cancel handler closes the descriptor it owns. All source
    /// suspend/resume/cancel calls happen on the main actor.
    func startAcceptSource(listenerSocket: Int32, generation: UInt64) {
        let source = DispatchSource.makeReadSource(fileDescriptor: listenerSocket, queue: socketListenerQueue)
        source.setEventHandler { @Sendable [weak self] in
            self?.drainPendingSocketClients(listenerSocket: listenerSocket, generation: generation)
        }
        source.setCancelHandler { @Sendable [weak self] in
            close(listenerSocket)
            guard let self else { return }
            Task { @MainActor in
                self.finishAcceptSourceCancel(listenerSocket: listenerSocket, generation: generation)
            }
        }

        let shouldResume = withListenerState { state in
            guard state.isRunning,
                  state.serverSocket == listenerSocket,
                  generation == state.activeAcceptLoopGeneration else {
                return false
            }
            state.listenerReadSource = source
            state.listenerReadSourceSuspended = false
            state.acceptLoopAlive = true
            return true
        }

        guard shouldResume else {
            source.cancel()
            source.resume()
            return
        }

        events.breadcrumb(
            "socket.listener.accept_source.started",
            socketListenerEventData(
                stage: "accept_source_start",
                extra: [
                    "generation": generation,
                    "listenerSocket": Int(listenerSocket),
                ]
            )
        )
        source.resume()
    }

    private func finishAcceptSourceCancel(listenerSocket: Int32, generation: UInt64) {
        withListenerState { state in
            guard state.activeAcceptLoopGeneration == generation,
                  state.serverSocket == listenerSocket else { return }
            state.acceptLoopAlive = false
            state.listenerReadSource = nil
            state.listenerReadSourceSuspended = false
        }
    }

    /// Drains pending accepts on the listener queue. State-free apart from
    /// the ``AcceptRecoveryState`` streak: staleness is checked against the
    /// published snapshot (the same window the legacy lock release between
    /// iterations allowed), and recovery decisions hop to the main actor.
    private nonisolated func drainPendingSocketClients(listenerSocket: Int32, generation: UInt64) {
        while shouldContinueAcceptLoop(listenerSocket: listenerSocket, generation: generation) {
            let clientSocket = accept(listenerSocket, nil, nil)

            guard clientSocket >= 0 else {
                let errnoCode = errno
                if errnoCode == EAGAIN || errnoCode == EWOULDBLOCK {
                    return
                }
                if errnoCode == EINTR || errnoCode == ECONNABORTED {
                    continue
                }
                handleAcceptFailure(
                    listenerSocket: listenerSocket,
                    generation: generation,
                    errnoCode: errnoCode
                )
                return
            }

            acceptRecovery.withLock { recovery in
                if recovery.generation == generation {
                    recovery.consecutiveFailures = 0
                }
            }

            if let failure = transport.configureAcceptedClientSocket(clientSocket) {
                if transport.shouldReportAcceptedClientConfigFailure(stage: failure.stage, errnoCode: failure.errnoCode) {
                    events.breadcrumb(
                        "socket.listener.client_config.failed",
                        socketListenerEventData(
                            stage: failure.stage,
                            errnoCode: failure.errnoCode,
                            extra: ["generation": generation]
                        )
                    )
                }
                close(clientSocket)
                continue
            }

            // Capture peer PID immediately, before short-lived clients can disconnect.
            let peerPid = transport.peerProcessID(of: clientSocket)
            let yielded = connectionsContinuation.yield(
                ControlConnection(socket: clientSocket, peerProcessID: peerPid)
            )
            if case .enqueued = yielded {} else {
                // Terminated or dropped stream: nobody owns the fd now.
                close(clientSocket)
            }
        }
    }

    private nonisolated func shouldContinueAcceptLoop(listenerSocket: Int32, generation: UInt64) -> Bool {
        let snapshot = listenerStateSnapshot()
        return snapshot.isRunning
            && snapshot.serverSocket == listenerSocket
            && generation == snapshot.activeGeneration
    }

    /// Classifies a hard accept failure on the listener queue, maintains the
    /// streak, and hops the recovery decision to the main actor at most once
    /// at a time. While a hop is in flight the source stays armed and may
    /// re-fire on a hot errno; those re-fires return here without counting
    /// or emitting, matching the legacy cadence where the source was already
    /// suspended by this point.
    private nonisolated func handleAcceptFailure(
        listenerSocket: Int32,
        generation: UInt64,
        errnoCode: Int32
    ) {
        let consecutiveFailures = acceptRecovery.withLock { recovery -> Int? in
            guard recovery.generation == generation, !recovery.recoveryHopInFlight else {
                return nil
            }
            recovery.consecutiveFailures += 1
            return recovery.consecutiveFailures
        }
        guard let consecutiveFailures else { return }

        let errnoClass = listenerPolicy.acceptErrorClassification(errnoCode: errnoCode)
        let recoveryAction = listenerPolicy.acceptFailureRecoveryAction(
            errnoCode: errnoCode,
            consecutiveFailures: consecutiveFailures
        )

        events.breadcrumb(
            "socket.listener.accept.failed",
            socketListenerEventData(
                stage: "accept_source",
                errnoCode: errnoCode,
                extra: [
                    "generation": generation,
                    "consecutiveFailures": consecutiveFailures,
                    "errnoClass": errnoClass.rawValue,
                    "recoveryAction": recoveryAction.debugLabel,
                ]
            )
        )

        if case .retryImmediately = recoveryAction {
            return
        }

        acceptRecovery.withLock { recovery in
            if recovery.generation == generation {
                recovery.recoveryHopInFlight = true
            }
        }
        Task { @MainActor in
            self.applyAcceptRecovery(
                recoveryAction,
                listenerSocket: listenerSocket,
                generation: generation,
                errnoCode: errnoCode,
                consecutiveFailures: consecutiveFailures
            )
        }
    }

    /// Applies a queue-reported recovery decision on the main actor, then
    /// releases the recovery latch. Stale reports (stop or restart landed
    /// first) are no-ops via the generation/descriptor guards.
    private func applyAcceptRecovery(
        _ recoveryAction: AcceptFailureRecoveryAction,
        listenerSocket: Int32,
        generation: UInt64,
        errnoCode: Int32,
        consecutiveFailures: Int
    ) {
        defer {
            acceptRecovery.withLock { recovery in
                if recovery.generation == generation {
                    recovery.recoveryHopInFlight = false
                }
            }
        }

        switch recoveryAction {
        case .retryImmediately:
            return
        case .resumeAfterDelay(let delayMs):
            scheduleAcceptSourceResume(
                listenerSocket: listenerSocket,
                generation: generation,
                errnoCode: errnoCode,
                consecutiveFailures: consecutiveFailures,
                delayMs: delayMs
            )
        case .rearmAfterDelay(let delayMs):
            let cleanup = withListenerState { state -> (didCleanup: Bool, sourceToCancel: (any DispatchSourceRead)?, sourceWasSuspended: Bool) in
                guard state.activeAcceptLoopGeneration == generation,
                      state.serverSocket == listenerSocket else {
                    return (didCleanup: false, sourceToCancel: nil, sourceWasSuspended: false)
                }
                state.pendingAcceptLoopRearmGeneration = generation
                state.isRunning = false
                state.acceptLoopAlive = false
                let source = state.listenerReadSource
                let sourceWasSuspended = state.listenerReadSourceSuspended
                state.listenerReadSource = nil
                state.listenerReadSourceSuspended = false
                state.serverSocket = -1
                shutdown(listenerSocket, SHUT_RDWR)
                if source == nil {
                    close(listenerSocket)
                }
                return (didCleanup: true, sourceToCancel: source, sourceWasSuspended: sourceWasSuspended)
            }
            guard cleanup.didCleanup else {
                return
            }
            if cleanup.sourceWasSuspended {
                cleanup.sourceToCancel?.resume()
            }
            cleanup.sourceToCancel?.cancel()

            events.rearmRequested(generation, errnoCode, consecutiveFailures, delayMs)
        }
    }

    private func scheduleAcceptSourceResume(
        listenerSocket: Int32,
        generation: UInt64,
        errnoCode: Int32,
        consecutiveFailures: Int,
        delayMs: Int
    ) {
        let suspendedSourceID = withListenerState { state -> ObjectIdentifier? in
            guard state.activeAcceptLoopGeneration == generation,
                  state.serverSocket == listenerSocket,
                  let source = state.listenerReadSource,
                  !state.listenerReadSourceSuspended else {
                return nil
            }
            source.suspend()
            state.listenerReadSourceSuspended = true
            return ObjectIdentifier(source)
        }
        guard let suspendedSourceID else {
            return
        }

        events.breadcrumb(
            "socket.listener.accept.resume_scheduled",
            socketListenerEventData(
                stage: "accept_source_resume",
                errnoCode: errnoCode,
                extra: [
                    "generation": generation,
                    "consecutiveFailures": consecutiveFailures,
                    "resumeDelayMs": delayMs,
                ]
            )
        )

        // Bounded, cancellable backoff deadline on the injected recovery
        // clock; ``stop()`` cancels it, and a stale fire is a no-op via the
        // generation/identity/suspended guards in the resume.
        acceptResumeTask?.cancel()
        acceptResumeTask = Task { [weak self, recoveryClock] in
            do {
                try await recoveryClock.sleep(forMilliseconds: delayMs)
            } catch {
                return
            }
            self?.resumeSuspendedAcceptSource(
                listenerSocket: listenerSocket,
                generation: generation,
                suspendedSourceID: suspendedSourceID
            )
        }
    }

    private func resumeSuspendedAcceptSource(
        listenerSocket: Int32,
        generation: UInt64,
        suspendedSourceID: ObjectIdentifier
    ) {
        withListenerState { state in
            guard state.activeAcceptLoopGeneration == generation,
                  state.serverSocket == listenerSocket,
                  state.isRunning,
                  let activeSource = state.listenerReadSource,
                  ObjectIdentifier(activeSource) == suspendedSourceID,
                  state.listenerReadSourceSuspended else {
                return
            }
            activeSource.resume()
            state.listenerReadSourceSuspended = false
        }
    }

    /// Claims the pending rearm for `generation`, emitting the rearm
    /// breadcrumb on success.
    ///
    /// The host calls this after the delay requested through
    /// ``SocketControlServerEvents/rearmRequested``; a non-`nil` return is the
    /// socket path to restart on (with the failure streak preserved).
    /// - Parameters:
    ///   - generation: The generation the rearm was parked under.
    ///   - errnoCode: The accept errno that triggered the rearm (telemetry).
    ///   - consecutiveFailures: The failure streak at rearm time (telemetry).
    ///   - delayMs: The delay that elapsed before the claim (telemetry).
    /// - Returns: The socket path to restart on, or `nil` when the rearm was
    ///   superseded by a stop or a newer listener.
    public func claimPendingRearm(
        generation: UInt64,
        errnoCode: Int32,
        consecutiveFailures: Int,
        delayMs: Int
    ) -> String? {
        let restartPath = withListenerState { state -> String? in
            guard state.pendingAcceptLoopRearmGeneration == generation else { return nil }
            state.pendingAcceptLoopRearmGeneration = nil
            return state.socketPath
        }
        guard let restartPath else { return nil }

        events.breadcrumb(
            "socket.listener.rearm.requested",
            socketListenerEventData(
                stage: "accept_rearm",
                errnoCode: errnoCode,
                extra: [
                    "generation": generation,
                    "consecutiveFailures": consecutiveFailures,
                    "rearmDelayMs": delayMs,
                ]
            )
        )
        return restartPath
    }
}
