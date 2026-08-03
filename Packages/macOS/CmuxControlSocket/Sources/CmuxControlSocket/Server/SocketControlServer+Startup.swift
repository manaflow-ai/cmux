public import CmuxSettings
internal import Darwin
internal import Foundation
internal import os

nonisolated private let socketControlServerLogger = Logger(
    subsystem: "com.cmux.socket",
    category: "Listener"
)

extension SocketControlServer {
    /// Reserves `path` (or its policy fallback) before the listener starts, so
    /// early startup consumers see the path the listener will actually bind.
    ///
    /// Acquires the socket-path lock for the reservation; ``start(socketPath:accessMode:preserveAcceptFailureStreak:)``
    /// consumes the held lock when it starts on the same path. No-op when any
    /// listener state is already active.
    /// - Parameter path: The preferred startup socket path.
    /// - Returns: The reserved path (`path` or its fallback), or `path`
    ///   unchanged when no reservation was possible.
    @discardableResult
    public func reserveStartupSocketPath(_ path: String) -> String {
        guard withListenerState({ Self.canReserveStartupSocketPath(state: $0) }) else {
            return path
        }

        var reservationPath = path
        var reservationLockFD: Int32 = -1
        var reservationCanReplaceRefusedSocket = false
        switch transport.acquireSocketPathLock(for: path) {
        case .acquired(let fd, let canReplaceRefusedSocket):
            reservationLockFD = fd
            reservationCanReplaceRefusedSocket = canReplaceRefusedSocket
        case .failed(let failure):
            if let fallbackPath = listenerPolicy.fallbackSocketPathAfterBindFailure(
                requestedPath: path,
                stage: failure.stage,
                errnoCode: failure.errnoCode
            ),
                fallbackPath != path,
                case .acquired(let fd, let canReplaceRefusedSocket) =
                    transport.acquireSocketPathLock(for: fallbackPath) {
                reservationPath = fallbackPath
                reservationLockFD = fd
                reservationCanReplaceRefusedSocket = canReplaceRefusedSocket
            }
        }

        guard reservationLockFD >= 0 else {
            return path
        }

        var didReserve = false
        withListenerState { state in
            guard Self.canReserveStartupSocketPath(state: state) else {
                return
            }
            state.socketPath = reservationPath
            state.reservedStartupSocketPath = reservationPath
            state.reservedStartupSocketPathCanReplaceRefusedSocket = reservationCanReplaceRefusedSocket
            state.socketPathLockFD = reservationLockFD
            didReserve = true
        }
        if didReserve {
            return reservationPath
        }
        transport.releaseSocketPathLock(reservationLockFD)
        return path
    }

    private static func canReserveStartupSocketPath(state: ListenerResources) -> Bool {
        !state.isRunning &&
            !state.acceptLoopAlive &&
            !state.listenerState.isStarting &&
            !state.listenerState.isWaiting &&
            state.pendingAcceptLoopRearmGeneration == nil &&
            state.socketPathLockFD < 0 &&
            state.listenerReadSource == nil &&
            state.socketPathMonitorSource == nil &&
            state.serverSocket < 0
    }

    /// Starts (or restarts) the listener on `socketPath`.
    ///
    /// Faithful lift of the legacy `TerminalController.start`: idempotent when
    /// already running on a matching path (re-applies permissions only),
    /// consumes a matching startup reservation's held path lock, stops any
    /// retained inactive listener state, binds with stale/refused replacement
    /// rules and a one-shot policy fallback path, then commits the running
    /// state under a fresh accept-loop generation and arms the path monitor
    /// and accept source. Transient startup failures schedule bounded recovery;
    /// permanent or exhausted failures are reported through the events seam.
    /// - Parameters:
    ///   - socketPath: The path to bind.
    ///   - accessMode: Socket access mode; drives file permissions, client
    ///     ancestry checks, and password auth.
    ///   - preserveAcceptFailureStreak: Keeps the consecutive accept-failure
    ///     counter across a rearm restart so backoff continues to escalate.
    /// - Returns: `true` when the listener activated synchronously. `false`
    ///   may mean bounded transient-failure recovery is pending.
    @discardableResult
    public func start(
        socketPath: String,
        accessMode: SocketControlMode,
        preserveAcceptFailureStreak: Bool = false
    ) -> Bool {
        let request = ListenerStartRequest(
            socketPath: socketPath,
            accessMode: accessMode,
            preserveAcceptFailureStreak: preserveAcceptFailureStreak
        )
        startupWakeTask?.cancel()
        startupWakeTask = nil

        if accessMode == .off {
            withListenerState { state in
                state.accessMode = .off
            }
            configureConnectionAuthorization(accessMode: .off)
            stop()
            return false
        }

        let existing = withListenerState { state in
            if state.accessMode != accessMode {
                state.accessMode = accessMode
            }
            return (
                isRunning: state.isRunning,
                socketPath: state.socketPath,
                reservedStartupSocketPath: state.reservedStartupSocketPath,
                socketPathLockHeld: state.socketPathLockFD >= 0,
                hasRetainedInactiveListenerState: !state.isRunning && (
                    state.boundSocketPathOwnership != .none ||
                        state.socketPathLockFD >= 0 ||
                        state.acceptLoopAlive ||
                        state.serverSocket >= 0 ||
                        state.listenerReadSource != nil ||
                        state.socketPathMonitorSource != nil
                )
            )
        }

        if existing.isRunning && SocketControlSettings.pathsMatch(existing.socketPath, socketPath) {
            configureConnectionAuthorization(accessMode: accessMode)
            if let errnoCode = applySocketPermissions() {
                stop()
                let generation = beginStart(request)
                _ = handleStartupFailure(
                    message: "socket.listener.start.failed",
                    stage: "chmod",
                    errnoCode: errnoCode,
                    request: request,
                    generation: generation
                )
                return false
            }
            withListenerState { state in
                let generation = state.listenerState.generation &+ 1
                state.listenerState = .idle(generation: generation)
            }
            return true
        }

        let canConsumeReservedStartupLock = !existing.isRunning
            && existing.socketPathLockHeld
            && existing.reservedStartupSocketPath.map { SocketControlSettings.pathsMatch($0, socketPath) } == true
        if existing.isRunning || (existing.hasRetainedInactiveListenerState && !canConsumeReservedStartupLock) {
            stop()
        }

        let generation = beginStart(request)
        return startAttempt(generation: generation)
    }

    private func beginStart(_ request: ListenerStartRequest) -> UInt64 {
        withListenerState { state in
            let generation = state.listenerState.generation &+ 1
            state.listenerState = .starting(
                generation: generation,
                request: request,
                failureCount: 0
            )
            return generation
        }
    }

    /// Applies the startup retry policy after a live listener was stopped
    /// because a permission update failed closed.
    func schedulePermissionRecovery(
        socketPath: String,
        accessMode: SocketControlMode,
        errnoCode: Int32
    ) {
        let request = ListenerStartRequest(
            socketPath: socketPath,
            accessMode: accessMode,
            preserveAcceptFailureStreak: false
        )
        let generation = beginStart(request)
        _ = handleStartupFailure(
            message: "socket.listener.start.failed",
            stage: "chmod",
            errnoCode: errnoCode,
            request: request,
            generation: generation
        )
    }

    private func startAttempt(generation: UInt64) -> Bool {
        guard let attempt = withListenerState({ state -> (ListenerStartRequest, Int)? in
            guard case .starting(let currentGeneration, let request, let failureCount) = state.listenerState,
                  currentGeneration == generation else {
                return nil
            }
            if state.accessMode != request.accessMode {
                state.accessMode = request.accessMode
            }
            return (request, failureCount)
        }) else { return false }
        let (request, _) = attempt
        configureConnectionAuthorization(accessMode: request.accessMode)

        var activeSocketPath = request.socketPath
        var activeSocketPathLockFD: Int32 = -1
        var activeSocketPathCanReplaceRefusedSocket = false
        var activeServerSocket: Int32 = -1
        var activeBoundSocketPathOwnership = BoundSocketPathOwnership.none
        var resumedIdentityPendingBind = false
        withListenerState { state in
            if state.boundSocketPathOwnership == .identityPending,
               state.serverSocket >= 0,
               state.socketPathLockFD >= 0,
               SocketControlSettings.pathsMatch(state.socketPath, activeSocketPath) {
                activeSocketPath = state.socketPath
                activeServerSocket = state.serverSocket
                activeSocketPathLockFD = state.socketPathLockFD
                activeBoundSocketPathOwnership = .identityPending
                state.serverSocket = -1
                state.socketPathLockFD = -1
                state.boundSocketPathOwnership = .none
                resumedIdentityPendingBind = true
            } else if state.socketPathLockFD >= 0,
               state.reservedStartupSocketPath.map({ SocketControlSettings.pathsMatch($0, activeSocketPath) }) == true,
               !state.isRunning,
               !state.acceptLoopAlive,
               state.serverSocket < 0 {
                activeSocketPathLockFD = state.socketPathLockFD
                activeSocketPathCanReplaceRefusedSocket = state.reservedStartupSocketPathCanReplaceRefusedSocket
                state.socketPathLockFD = -1
            }
            state.socketPath = activeSocketPath
            if !resumedIdentityPendingBind {
                state.boundSocketPathOwnership = .none
            }
            state.reservedStartupSocketPath = nil
            state.reservedStartupSocketPathCanReplaceRefusedSocket = false
        }
        var listenerActivated = false
        defer {
            if !listenerActivated {
                unlinkOwnedSocketPath(
                    activeSocketPath,
                    ownership: activeBoundSocketPathOwnership,
                    listenerSocket: activeServerSocket,
                    pathLockFD: activeSocketPathLockFD
                )
                if activeServerSocket >= 0 {
                    close(activeServerSocket)
                    activeServerSocket = -1
                }
                transport.releaseSocketPathLock(activeSocketPathLockFD)
                activeSocketPathLockFD = -1
                withListenerState { state in
                    if state.serverSocket < 0, state.socketPathLockFD < 0 {
                        state.boundSocketPathOwnership = .none
                    }
                }
            }
        }

        if resumedIdentityPendingBind {
            let identityResult = transport.boundPathIdentityResult(at: activeSocketPath)
            guard let identity = identityResult.identity else {
                let disposition = handleStartupFailure(
                    message: "socket.listener.start.failed",
                    stage: "stat_bound_path",
                    errnoCode: identityResult.errnoCode ?? EIO,
                    request: ListenerStartRequest(
                        socketPath: activeSocketPath,
                        accessMode: request.accessMode,
                        preserveAcceptFailureStreak: request.preserveAcceptFailureStreak
                    ),
                    generation: generation,
                    retainedSocket: activeServerSocket,
                    retainedPathLockFD: activeSocketPathLockFD,
                    retainedOwnership: .identityPending
                )
                if disposition == .retryScheduled {
                    activeServerSocket = -1
                    activeSocketPathLockFD = -1
                    activeBoundSocketPathOwnership = .none
                }
                return false
            }
            activeBoundSocketPathOwnership = .identified(identity)
        } else {
            let (newServerSocket, createSocketErrno) = transport.makeListenerSocket()
            guard newServerSocket >= 0 else {
                let errnoCode = createSocketErrno ?? EIO
                socketControlServerLogger.error("Failed to create listener socket")
                _ = handleStartupFailure(
                    message: "socket.listener.start.failed",
                    stage: "create_socket",
                    errnoCode: errnoCode,
                    request: request,
                    generation: generation
                )
                return false
            }
            activeServerSocket = newServerSocket

            func acquireActiveSocketPathLock() -> SocketBindAttemptResult? {
                if activeSocketPathLockFD >= 0 {
                    return nil
                }
                switch transport.acquireSocketPathLock(for: activeSocketPath) {
                case .acquired(let fd, let canReplaceRefusedSocket):
                    activeSocketPathLockFD = fd
                    activeSocketPathCanReplaceRefusedSocket = canReplaceRefusedSocket
                    return nil
                case .failed(let failure):
                    return .failure(path: activeSocketPath, failure: failure)
                }
            }

            var bindAttempt = acquireActiveSocketPathLock()
                ?? transport.bindListenerSocket(
                    activeServerSocket,
                    path: activeSocketPath,
                    canReplaceRefusedSocket: activeSocketPathCanReplaceRefusedSocket
                )
            if case .failure(let failedPath, let bindFailure) = bindAttempt,
               bindFailure.stage != "stat_bound_path",
               let fallbackPath = listenerPolicy.fallbackSocketPathAfterBindFailure(
                   requestedPath: failedPath,
                   stage: bindFailure.stage,
                   errnoCode: bindFailure.errnoCode
               ),
               fallbackPath != failedPath {
                events.breadcrumb(
                    "socket.listener.path.fallback",
                    [
                        "requestedPath": failedPath,
                        "fallbackPath": fallbackPath,
                        "stage": bindFailure.stage,
                        "errno": Int(bindFailure.errnoCode),
                    ]
                )
                transport.releaseSocketPathLock(activeSocketPathLockFD)
                activeSocketPathLockFD = -1
                activeSocketPathCanReplaceRefusedSocket = false
                activeSocketPath = fallbackPath
                withListenerState { state in
                    state.socketPath = activeSocketPath
                }
                bindAttempt = acquireActiveSocketPathLock()
                    ?? transport.bindListenerSocket(
                        activeServerSocket,
                        path: activeSocketPath,
                        canReplaceRefusedSocket: activeSocketPathCanReplaceRefusedSocket
                    )
            }

            switch bindAttempt {
            case .success(let boundPath, let identity):
                activeSocketPath = boundPath
                activeBoundSocketPathOwnership = .identified(identity)
            case .pathTooLong(let failedPath):
                _ = handleStartupFailure(
                    message: "socket.listener.start.failed",
                    stage: "bind_path_too_long",
                    errnoCode: ENAMETOOLONG,
                    extra: [
                        "path": failedPath,
                        "pathLength": failedPath.utf8.count,
                        "maxPathLength": SocketTransport.unixSocketPathMaxLength,
                    ],
                    request: ListenerStartRequest(
                        socketPath: activeSocketPath,
                        accessMode: request.accessMode,
                        preserveAcceptFailureStreak: request.preserveAcceptFailureStreak
                    ),
                    generation: generation
                )
                return false
            case .failure(let failedPath, let bindFailure) where bindFailure.stage == "stat_bound_path":
                activeSocketPath = failedPath
                activeBoundSocketPathOwnership = .identityPending
                let disposition = handleStartupFailure(
                    message: "socket.listener.start.failed",
                    stage: bindFailure.stage,
                    errnoCode: bindFailure.errnoCode,
                    extra: ["path": failedPath],
                    request: ListenerStartRequest(
                        socketPath: activeSocketPath,
                        accessMode: request.accessMode,
                        preserveAcceptFailureStreak: request.preserveAcceptFailureStreak
                    ),
                    generation: generation,
                    retainedSocket: activeServerSocket,
                    retainedPathLockFD: activeSocketPathLockFD,
                    retainedOwnership: .identityPending
                )
                if disposition == .retryScheduled {
                    activeServerSocket = -1
                    activeSocketPathLockFD = -1
                    activeBoundSocketPathOwnership = .none
                }
                return false
            case .failure(let failedPath, let bindFailure):
                socketControlServerLogger.error("Failed to bind listener socket")
                _ = handleStartupFailure(
                    message: "socket.listener.start.failed",
                    stage: bindFailure.stage,
                    errnoCode: bindFailure.errnoCode,
                    extra: ["path": failedPath],
                    request: ListenerStartRequest(
                        socketPath: activeSocketPath,
                        accessMode: request.accessMode,
                        preserveAcceptFailureStreak: request.preserveAcceptFailureStreak
                    ),
                    generation: generation
                )
                return false
            }

            withListenerState { state in
                state.socketPath = activeSocketPath
            }
        }

        if let errnoCode = applySocketPermissions() {
            _ = handleStartupFailure(
                message: "socket.listener.start.failed",
                stage: "chmod",
                errnoCode: errnoCode,
                request: ListenerStartRequest(
                    socketPath: activeSocketPath,
                    accessMode: request.accessMode,
                    preserveAcceptFailureStreak: request.preserveAcceptFailureStreak
                ),
                generation: generation
            )
            return false
        }

        if let errnoCode = transport.configureNonBlocking(activeServerSocket) {
            socketControlServerLogger.error("Failed to configure listener socket")
            _ = handleStartupFailure(
                message: "socket.listener.start.failed",
                stage: "configure_nonblocking",
                errnoCode: errnoCode,
                request: ListenerStartRequest(
                    socketPath: activeSocketPath,
                    accessMode: request.accessMode,
                    preserveAcceptFailureStreak: request.preserveAcceptFailureStreak
                ),
                generation: generation
            )
            return false
        }

        // Listen
        guard listen(activeServerSocket, transport.listenBacklog) >= 0 else {
            let errnoCode = errno
            socketControlServerLogger.error("Failed to listen on socket")
            _ = handleStartupFailure(
                message: "socket.listener.start.failed",
                stage: "listen",
                errnoCode: errnoCode,
                request: ListenerStartRequest(
                    socketPath: activeSocketPath,
                    accessMode: request.accessMode,
                    preserveAcceptFailureStreak: request.preserveAcceptFailureStreak
                ),
                generation: generation
            )
            return false
        }

        transport.markSocketPathLockReusable(activeSocketPathLockFD)
        events.recordLastSocketPath(activeSocketPath)

        var displacedSocketPathLockFD: Int32 = -1
        let transferredSocketPathLockFD = activeSocketPathLockFD
        let acceptGeneration = withListenerState { state in
            state.isRunning = true
            state.pendingAcceptLoopRearmGeneration = nil
            state.nextAcceptLoopGeneration &+= 1
            let acceptGeneration = state.nextAcceptLoopGeneration
            state.activeAcceptLoopGeneration = acceptGeneration
            state.serverSocket = activeServerSocket
            displacedSocketPathLockFD = state.socketPathLockFD
            state.socketPathLockFD = activeSocketPathLockFD
            state.boundSocketPathOwnership = activeBoundSocketPathOwnership
            state.listenerState = .idle(generation: generation)
            return acceptGeneration
        }
        activateConnectionAuthorizations()
        acceptRecovery.withLock { recovery in
            recovery = AcceptRecoveryState(
                generation: acceptGeneration,
                consecutiveFailures: request.preserveAcceptFailureStreak ? recovery.consecutiveFailures : 0,
                recoveryHopInFlight: false
            )
        }
        if displacedSocketPathLockFD >= 0, displacedSocketPathLockFD != transferredSocketPathLockFD {
            transport.releaseSocketPathLock(displacedSocketPathLockFD)
        }
        activeServerSocket = -1
        activeSocketPathLockFD = -1
        activeBoundSocketPathOwnership = .none
        listenerActivated = true
        let listenerSocket = withListenerState { $0.serverSocket }
        socketControlServerLogger.info("Listening on \(activeSocketPath, privacy: .private)")
        events.breadcrumb(
            "socket.listener.listening",
            [
                "path": activeSocketPath,
                "mode": request.accessMode.rawValue,
                "generation": acceptGeneration,
                "backlog": transport.listenBacklog,
            ]
        )
        events.listenerDidStart(activeSocketPath, acceptGeneration)

        startSocketPathMonitor(path: activeSocketPath, generation: acceptGeneration)
        startAcceptSource(listenerSocket: listenerSocket, generation: acceptGeneration)
        return true
    }

    private enum StartupFailureDisposition {
        case retryScheduled
        case terminal
    }

    @discardableResult
    private func handleStartupFailure(
        message: String,
        stage: String,
        errnoCode: Int32,
        extra: [String: any Sendable] = [:],
        request: ListenerStartRequest,
        generation: UInt64,
        retainedSocket: Int32 = -1,
        retainedPathLockFD: Int32 = -1,
        retainedOwnership: BoundSocketPathOwnership = .none
    ) -> StartupFailureDisposition {
        guard let failureCount = withListenerState({ state -> Int? in
            guard case .starting(let currentGeneration, _, let currentFailureCount) = state.listenerState,
                  currentGeneration == generation else { return nil }
            return currentFailureCount + 1
        }) else { return .terminal }
        guard listenerPolicy.shouldRetryStartupFailure(
            stage: stage,
            errnoCode: errnoCode,
            consecutiveFailures: failureCount
        ) else {
            var reportExtra = extra
            reportExtra["startupFailureCount"] = failureCount
            let shouldReport = withListenerState { state -> Bool in
                guard case .starting(let currentGeneration, _, _) = state.listenerState,
                      currentGeneration == generation else { return false }
                state.listenerState = .idle(generation: generation)
                return true
            }
            guard shouldReport else { return .terminal }
            reportSocketListenerFailure(
                message: message,
                stage: stage,
                errnoCode: errnoCode,
                extra: reportExtra
            )
            return .terminal
        }

        let delayMs = listenerPolicy.startupFailureRetryDelayMilliseconds(
            consecutiveFailures: failureCount
        )
        var retryExtra = extra
        retryExtra["startupFailureCount"] = failureCount
        retryExtra["retryDelayMs"] = delayMs
        events.breadcrumb(
            "socket.listener.start.retry_scheduled",
            socketListenerEventData(
                stage: stage,
                errnoCode: errnoCode,
                extra: retryExtra
            )
        )

        let didSchedule = withListenerState { state -> Bool in
            guard case .starting(let currentGeneration, _, _) = state.listenerState,
                  currentGeneration == generation else { return false }
            state.socketPath = request.socketPath
            state.listenerState = .waiting(
                generation: generation,
                request: request,
                failureCount: failureCount
            )
            if retainedSocket >= 0,
               retainedPathLockFD >= 0,
               retainedOwnership == .identityPending {
                state.serverSocket = retainedSocket
                state.socketPathLockFD = retainedPathLockFD
                state.boundSocketPathOwnership = retainedOwnership
            }
            return true
        }
        guard didSchedule else { return .terminal }
        startupWakeTask?.cancel()
        // The task owns only the bounded delay. ListenerState owns every
        // lifecycle value and wakeStartupRetry atomically claims it.
        startupWakeTask = Task { [weak self, recoveryClock] in
            do {
                try await recoveryClock.sleep(forMilliseconds: delayMs)
                try Task.checkCancellation()
            } catch {
                return
            }
            self?.wakeStartupRetry(generation: generation)
        }
        return .retryScheduled
    }

    /// Atomically claims a matching delayed retry before starting any syscall work.
    private func wakeStartupRetry(generation: UInt64) {
        let didClaim = withListenerState { state -> Bool in
            guard case .waiting(let currentGeneration, let request, let failureCount) = state.listenerState,
                  currentGeneration == generation else { return false }
            state.listenerState = .starting(
                generation: generation,
                request: request,
                failureCount: failureCount
            )
            return true
        }
        guard didClaim else { return }
        startupWakeTask = nil
        _ = startAttempt(generation: generation)
    }

    /// Removes a bound path only with an identity proof, including recovery
    /// from an initially pending identity while both descriptor and lock remain held.
    func unlinkOwnedSocketPath(
        _ path: String,
        ownership: BoundSocketPathOwnership,
        listenerSocket: Int32,
        pathLockFD: Int32
    ) {
        let resolvedOwnership: BoundSocketPathOwnership
        switch ownership {
        case .none:
            return
        case .identified:
            resolvedOwnership = ownership
        case .identityPending:
            guard listenerSocket >= 0,
                  pathLockFD >= 0,
                  let identity = transport.boundPathIdentityResult(at: path).identity else {
                return
            }
            resolvedOwnership = .identified(identity)
        }
        guard listenerPolicy.shouldUnlinkSocketPathAfterListenerStop(
            currentIdentity: transport.pathIdentity(at: path),
            boundIdentity: resolvedOwnership.identity
        ) else { return }
        unlink(path)
    }

    /// Applies the access mode's file permissions to the current socket path.
    @discardableResult
    func applySocketPermissions() -> Int32? {
        let (currentSocketPath, mode) = withListenerState { ($0.socketPath, $0.accessMode) }
        let permissions = mode_t(mode.socketFilePermissions)
        if let errnoCode = transport.applySocketPermissions(permissions, at: currentSocketPath) {
            let permissionsDescription = String(permissions, radix: 8)
            socketControlServerLogger.error(
                "Failed to set socket permissions to \(permissionsDescription, privacy: .public) for \(currentSocketPath, privacy: .private)"
            )
            events.breadcrumb(
                "socket.listener.permissions.failed",
                socketListenerEventData(
                    stage: "chmod",
                    errnoCode: errnoCode,
                    extra: ["permissions": String(permissions, radix: 8)]
                )
            )
            return errnoCode
        }
        return nil
    }

}
