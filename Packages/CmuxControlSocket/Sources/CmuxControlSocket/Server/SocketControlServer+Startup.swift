public import CmuxSettings
internal import CmuxSocketControl
internal import Darwin
internal import Foundation

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

    private static func canReserveStartupSocketPath(state: ListenerState) -> Bool {
        !state.isRunning &&
            !state.acceptLoopAlive &&
            !state.listenerStartInProgress &&
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
    /// and accept source. Failures are reported through the events seam.
    /// - Parameters:
    ///   - socketPath: The path to bind.
    ///   - accessMode: Socket access mode; drives file permissions, client
    ///     ancestry checks, and password auth.
    ///   - preserveAcceptFailureStreak: Keeps the consecutive accept-failure
    ///     counter across a rearm restart so backoff continues to escalate.
    /// - Returns: `true` when the listener activated.
    @discardableResult
    public func start(
        socketPath: String,
        accessMode: SocketControlMode,
        preserveAcceptFailureStreak: Bool = false
    ) -> Bool {
        let existing = withListenerState { state in
            state.accessMode = accessMode
            return (
                isRunning: state.isRunning,
                socketPath: state.socketPath,
                reservedStartupSocketPath: state.reservedStartupSocketPath,
                socketPathLockHeld: state.socketPathLockFD >= 0,
                hasRetainedInactiveListenerState: !state.isRunning && (
                    state.pendingAcceptLoopRearmGeneration != nil ||
                        state.socketPathLockFD >= 0 ||
                        state.acceptLoopAlive ||
                        state.serverSocket >= 0 ||
                        state.listenerReadSource != nil ||
                        state.socketPathMonitorSource != nil
                )
            )
        }

        if existing.isRunning && SocketControlSettings.pathsMatch(existing.socketPath, socketPath) {
            applySocketPermissions()
            return true
        }

        let canConsumeReservedStartupLock = !existing.isRunning
            && existing.socketPathLockHeld
            && existing.reservedStartupSocketPath.map { SocketControlSettings.pathsMatch($0, socketPath) } == true
        if existing.isRunning || (existing.hasRetainedInactiveListenerState && !canConsumeReservedStartupLock) {
            stop()
        }

        var activeSocketPath = socketPath
        var activeSocketPathLockFD: Int32 = -1
        var activeSocketPathCanReplaceRefusedSocket = false
        var activeBoundSocketPathIdentity: SocketPathIdentity?
        withListenerState { state in
            if state.socketPathLockFD >= 0,
               state.reservedStartupSocketPath.map({ SocketControlSettings.pathsMatch($0, activeSocketPath) }) == true,
               !state.isRunning,
               !state.acceptLoopAlive,
               state.serverSocket < 0 {
                activeSocketPathLockFD = state.socketPathLockFD
                activeSocketPathCanReplaceRefusedSocket = state.reservedStartupSocketPathCanReplaceRefusedSocket
                state.socketPathLockFD = -1
            }
            state.socketPath = activeSocketPath
            state.boundSocketPathIdentity = nil
            state.reservedStartupSocketPath = nil
            state.reservedStartupSocketPathCanReplaceRefusedSocket = false
            state.listenerStartInProgress = true
        }
        var listenerActivated = false
        defer {
            if !listenerActivated {
                if let activeBoundSocketPathIdentity,
                   listenerPolicy.shouldUnlinkSocketPathAfterListenerStop(
                       currentIdentity: transport.pathIdentity(at: activeSocketPath),
                       boundIdentity: activeBoundSocketPathIdentity
                   ) {
                    unlink(activeSocketPath)
                }
                transport.releaseSocketPathLock(activeSocketPathLockFD)
                activeSocketPathLockFD = -1
                withListenerState { state in
                    if state.boundSocketPathIdentity == activeBoundSocketPathIdentity {
                        state.boundSocketPathIdentity = nil
                    }
                    state.listenerStartInProgress = false
                }
            }
        }

        // Create socket
        let newServerSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard newServerSocket >= 0 else {
            let errnoCode = errno
            print("SocketControlServer: Failed to create socket")
            reportSocketListenerFailure(
                message: "socket.listener.start.failed",
                stage: "create_socket",
                errnoCode: errnoCode
            )
            return false
        }

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
            ?? bindListenerSocketOnListenerQueue(
                newServerSocket,
                path: activeSocketPath,
                canReplaceRefusedSocket: activeSocketPathCanReplaceRefusedSocket
            )
        if case .failure(let failedPath, let bindFailure) = bindAttempt,
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
                ?? bindListenerSocketOnListenerQueue(
                    newServerSocket,
                    path: activeSocketPath,
                    canReplaceRefusedSocket: activeSocketPathCanReplaceRefusedSocket
                )
        }

        switch bindAttempt {
        case .success(let boundPath, let identity):
            activeSocketPath = boundPath
            activeBoundSocketPathIdentity = identity
            withListenerState { state in
                state.socketPath = activeSocketPath
                state.boundSocketPathIdentity = identity
            }
        case .pathTooLong(let failedPath):
            close(newServerSocket)
            reportSocketListenerFailure(
                message: "socket.listener.start.failed",
                stage: "bind_path_too_long",
                errnoCode: ENAMETOOLONG,
                extra: [
                    "path": failedPath,
                    "pathLength": failedPath.utf8.count,
                    "maxPathLength": SocketTransport.unixSocketPathMaxLength,
                ]
            )
            return false
        case .failure(let failedPath, let bindFailure):
            print("SocketControlServer: Failed to bind socket")
            close(newServerSocket)
            reportSocketListenerFailure(
                message: "socket.listener.start.failed",
                stage: bindFailure.stage,
                errnoCode: bindFailure.errnoCode,
                extra: ["path": failedPath]
            )
            return false
        }

        applySocketPermissions()

        if let errnoCode = transport.configureNonBlocking(newServerSocket) {
            print("SocketControlServer: Failed to configure socket")
            close(newServerSocket)
            reportSocketListenerFailure(
                message: "socket.listener.start.failed",
                stage: "configure_nonblocking",
                errnoCode: errnoCode
            )
            return false
        }

        // Listen
        guard listen(newServerSocket, transport.listenBacklog) >= 0 else {
            let errnoCode = errno
            print("SocketControlServer: Failed to listen on socket")
            close(newServerSocket)
            reportSocketListenerFailure(
                message: "socket.listener.start.failed",
                stage: "listen",
                errnoCode: errnoCode
            )
            return false
        }

        transport.markSocketPathLockReusable(activeSocketPathLockFD)
        events.recordLastSocketPath(activeSocketPath)

        var displacedSocketPathLockFD: Int32 = -1
        let transferredSocketPathLockFD = activeSocketPathLockFD
        let generation = withListenerState { state in
            state.isRunning = true
            state.pendingAcceptLoopRearmGeneration = nil
            if !preserveAcceptFailureStreak {
                state.acceptSourceConsecutiveFailures = 0
            }
            state.nextAcceptLoopGeneration &+= 1
            let generation = state.nextAcceptLoopGeneration
            state.activeAcceptLoopGeneration = generation
            state.serverSocket = newServerSocket
            displacedSocketPathLockFD = state.socketPathLockFD
            state.socketPathLockFD = activeSocketPathLockFD
            state.listenerStartInProgress = false
            return generation
        }
        if displacedSocketPathLockFD >= 0, displacedSocketPathLockFD != transferredSocketPathLockFD {
            transport.releaseSocketPathLock(displacedSocketPathLockFD)
        }
        activeSocketPathLockFD = -1
        listenerActivated = true
        let listenerSocket = newServerSocket
        print("SocketControlServer: Listening on \(activeSocketPath)")
        events.breadcrumb(
            "socket.listener.listening",
            [
                "path": activeSocketPath,
                "mode": accessMode.rawValue,
                "generation": generation,
                "backlog": transport.listenBacklog,
            ]
        )
        events.listenerDidStart(activeSocketPath, generation)

        startSocketPathMonitor(path: activeSocketPath, generation: generation)
        startAcceptSource(listenerSocket: listenerSocket, generation: generation)
        return true
    }

    /// Applies the access mode's file permissions to the current socket path.
    func applySocketPermissions() {
        let (currentSocketPath, mode) = withListenerState { ($0.socketPath, $0.accessMode) }
        let permissions = mode_t(mode.socketFilePermissions)
        if chmod(currentSocketPath, permissions) != 0 {
            let errnoCode = errno
            print(
                "TerminalController: Failed to set socket permissions to \(String(permissions, radix: 8)) for \(currentSocketPath)"
            )
            events.breadcrumb(
                "socket.listener.permissions.failed",
                socketListenerEventData(
                    stage: "chmod",
                    errnoCode: errnoCode,
                    extra: ["permissions": String(permissions, radix: 8)]
                )
            )
        }
    }

    private func bindListenerSocketOnListenerQueue(
        _ socket: Int32,
        path: String,
        canReplaceRefusedSocket: Bool
    ) -> SocketBindAttemptResult {
        socketListenerQueue.sync {
            transport.bindListenerSocket(
                socket,
                path: path,
                canReplaceRefusedSocket: canReplaceRefusedSocket
            )
        }
    }
}
