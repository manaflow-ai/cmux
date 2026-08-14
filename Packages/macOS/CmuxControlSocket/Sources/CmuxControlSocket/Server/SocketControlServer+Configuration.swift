public import CmuxSettings

extension SocketControlServer {
    /// Records the resolved preferred path and reports real configuration drift.
    ///
    /// The first value establishes an inactive baseline independently of any
    /// reserved fallback path. For an already-running untracked listener, a
    /// mismatch reports drift so the host can rebind to the resolved path.
    @discardableResult
    public func updateConfiguredPreferredSocketPath(_ path: String) -> Bool {
        withListenerState { state in
            let changed = state.configuredPreferredSocketPath.map {
                !SocketControlSettings.pathsMatch($0, path)
            } ?? ((state.isRunning || state.pendingAcceptLoopRearmGeneration != nil)
                && !SocketControlSettings.pathsMatch(state.socketPath, path))
            state.configuredPreferredSocketPath = path
            return changed
        }
    }

    /// Replaces the live access policy used by subsequent client decisions.
    ///
    /// The policy is published through the server's synchronous state snapshot,
    /// so connection workers observe the new mode without a listener restart.
    /// File permissions are reapplied for an active listener. Configuring
    /// ``SocketControlMode/off`` stops the listener instead of leaving an open
    /// socket whose command checks could accidentally interpret `off` as a
    /// permissive non-`cmuxOnly` mode.
    ///
    /// - Parameter accessMode: The current resolved access mode.
    /// - Returns: Whether the live listener accepted the configuration.
    @discardableResult
    public func reconfigure(accessMode: SocketControlMode) -> Bool {
        let previousMode = withListenerState { state in
            let previousMode = state.accessMode
            if accessMode != previousMode {
                state.accessMode = accessMode
            }
            return previousMode
        }
        configureConnectionAuthorization(accessMode: accessMode)

        if accessMode == .off {
            stop()
        } else if isRunning, !applySocketPermissions() {
            stop()
            events.breadcrumb(
                "socket.listener.configuration.failed_closed",
                socketListenerEventData(
                    stage: "configuration",
                    extra: [
                        "previousMode": previousMode.rawValue,
                        "mode": accessMode.rawValue,
                    ]
                )
            )
            return false
        }

        events.breadcrumb(
            "socket.listener.configuration.applied",
            socketListenerEventData(
                stage: "configuration",
                extra: [
                    "previousMode": previousMode.rawValue,
                    "mode": accessMode.rawValue,
                ]
            )
        )
        return true
    }
}
