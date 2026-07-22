internal import Darwin
internal import Foundation

extension SocketControlServer {
    /// Stops the listener: tears down the accept and path-monitor sources,
    /// cancels any pending accept-source resume, shuts down and closes the
    /// server socket, unlinks the socket path when the listener still owns
    /// it, and releases the path lock.
    ///
    /// Synchronous on the main actor, where every caller already lives — the
    /// app's termination and updater-relaunch paths call it directly, so the
    /// unlink and lock release complete before the process exits.
    public func stop() {
        deactivateConnectionAuthorizations()
        acceptResumeTask?.cancel()
        acceptResumeTask = nil
        let (
            sourceToCancel,
            sourceWasSuspended,
            monitorToCancel,
            socketToShutdown,
            socketToClose,
            socketPathToUnlink,
            boundSocketPathIdentityToUnlink,
            socketPathLockFDToClose
        ) = withListenerState { state in
            state.isRunning = false
            state.acceptLoopAlive = false
            state.pendingAcceptLoopRearmGeneration = nil
            state.reservedStartupSocketPath = nil
            state.reservedStartupSocketPathCanReplaceRefusedSocket = false
            state.listenerStartInProgress = false
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
            let identity = state.boundSocketPathIdentity
            state.boundSocketPathIdentity = nil
            let lockFD = state.socketPathLockFD
            state.socketPathLockFD = -1
            return (
                sourceToCancel,
                sourceWasSuspended,
                monitorToCancel,
                socketToClose,
                sourceToCancel == nil ? socketToClose : Int32(-1),
                state.socketPath,
                identity,
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
        if socketToClose >= 0 {
            close(socketToClose)
        }
        if listenerPolicy.shouldUnlinkSocketPathAfterListenerStop(
            currentIdentity: transport.pathIdentity(at: socketPathToUnlink),
            boundIdentity: boundSocketPathIdentityToUnlink
        ) {
            unlink(socketPathToUnlink)
        }
        transport.releaseSocketPathLock(socketPathLockFDToClose)
    }
}
