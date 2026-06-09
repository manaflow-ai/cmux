internal import Darwin
internal import Foundation

extension SocketControlServer {
    /// Arms the accept read source for `listenerSocket` under `generation`.
    ///
    /// `DispatchSource.makeReadSource` carve-out: low-level socket I/O event
    /// delivery with no async-native equivalent. The source delivers on the
    /// listener queue — this actor's executor — so its handlers enter
    /// isolation synchronously via `assumeIsolated`.
    func startAcceptSource(listenerSocket: Int32, generation: UInt64) {
        let source = DispatchSource.makeReadSource(fileDescriptor: listenerSocket, queue: socketListenerQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.assumeIsolated { isolatedServer in
                isolatedServer.drainPendingSocketClients(
                    listenerSocket: listenerSocket,
                    generation: generation
                )
            }
        }
        source.setCancelHandler { [weak self] in
            close(listenerSocket)
            guard let self else { return }
            self.assumeIsolated { isolatedServer in
                isolatedServer.finishAcceptSourceCancel(
                    listenerSocket: listenerSocket,
                    generation: generation
                )
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

    private func drainPendingSocketClients(listenerSocket: Int32, generation: UInt64) {
        while shouldContinueAcceptLoop(generation: generation) {
            let clientSocket = accept(listenerSocket, nil, nil)

            guard clientSocket >= 0 else {
                let errnoCode = errno
                if errnoCode == EAGAIN || errnoCode == EWOULDBLOCK {
                    return
                }
                if errnoCode == EINTR || errnoCode == ECONNABORTED {
                    continue
                }
                handleAcceptSourceFailure(
                    listenerSocket: listenerSocket,
                    generation: generation,
                    errnoCode: errnoCode
                )
                return
            }

            withListenerState { state in
                state.acceptSourceConsecutiveFailures = 0
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
            connectionsContinuation.yield(
                ControlConnection(socket: clientSocket, peerProcessID: peerPid)
            )
        }
    }

    private func handleAcceptSourceFailure(
        listenerSocket: Int32,
        generation: UInt64,
        errnoCode: Int32
    ) {
        let errnoClass = listenerPolicy.acceptErrorClassification(errnoCode: errnoCode)
        let consecutiveFailures = withListenerState { state in
            guard state.activeAcceptLoopGeneration == generation,
                  state.serverSocket == listenerSocket else { return 0 }
            state.acceptSourceConsecutiveFailures += 1
            return state.acceptSourceConsecutiveFailures
        }
        guard consecutiveFailures > 0 else { return }

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
            return
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
            await self?.resumeSuspendedAcceptSource(
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
