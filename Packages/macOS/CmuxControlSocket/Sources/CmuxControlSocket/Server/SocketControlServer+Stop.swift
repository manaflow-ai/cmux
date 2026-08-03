internal import Darwin
internal import Foundation

extension SocketControlServer {
    /// Stops the listener: tears down the accept and path-monitor sources,
    /// cancels any pending startup retry or accept-source resume, shuts down
    /// and closes the server socket, unlinks the socket path when the listener
    /// still owns it, and releases the path lock.
    ///
    /// Synchronous on the main actor, where every caller already lives — the
    /// app's termination and updater-relaunch paths call it directly, so the
    /// unlink and lock release complete before the process exits.
    public func stop() {
        deactivateConnectionAuthorizations()
        acceptResumeTask?.cancel()
        acceptResumeTask = nil
        startupWakeTask?.cancel()
        startupWakeTask = nil
        let (
            sourceToCancel,
            sourceWasSuspended,
            monitorToCancel,
            socketToShutdown,
            socketToClose,
            socketPathToUnlink,
            boundSocketPathOwnershipToUnlink,
            socketPathLockFDToClose
        ) = withListenerState { state in
            state.isRunning = false
            state.acceptLoopAlive = false
            state.pendingAcceptLoopRearmGeneration = nil
            state.reservedStartupSocketPath = nil
            state.reservedStartupSocketPathCanReplaceRefusedSocket = false
            let startupGeneration = state.listenerState.generation &+ 1
            state.listenerState = .idle(generation: startupGeneration)
            state.nextAcceptLoopGeneration &+= 1
            state.activeAcceptLoopGeneration = 0
            let sourceToCancel = state.listenerReadSource
            let sourceWasSuspended = state.listenerReadSourceSuspended
            state.listenerReadSource = nil
            state.listenerReadSourceSuspended = false
            let monitorToCancel = state.socketPathMonitorSource
            state.socketPathMonitorSource = nil
            let socketToClose = state.serverSocket
            state.serverSocket = -1
            let ownership = state.boundSocketPathOwnership
            state.boundSocketPathOwnership = .none
            let lockFD = state.socketPathLockFD
            state.socketPathLockFD = -1
            return (
                sourceToCancel,
                sourceWasSuspended,
                monitorToCancel,
                socketToClose,
                sourceToCancel == nil ? socketToClose : Int32(-1),
                state.socketPath,
                ownership,
                lockFD
            )
        }
        if socketToShutdown >= 0 {
            shutdown(socketToShutdown, SHUT_RDWR)
        }
        if sourceWasSuspended {
            sourceToCancel?.resume()
        }
        sourceToCancel?.cancel()
        monitorToCancel?.cancel()
        unlinkOwnedSocketPath(
            socketPathToUnlink,
            ownership: boundSocketPathOwnershipToUnlink,
            listenerSocket: socketToShutdown,
            pathLockFD: socketPathLockFDToClose
        )
        if socketToClose >= 0 {
            close(socketToClose)
        }
        transport.releaseSocketPathLock(socketPathLockFDToClose)
    }
}
