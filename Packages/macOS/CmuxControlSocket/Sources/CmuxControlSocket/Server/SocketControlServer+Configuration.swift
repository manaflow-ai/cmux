public import CmuxSettings

extension SocketControlServer {
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
                state.connectionAuthorizationGeneration &+= 1
            }
            return previousMode
        }

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
