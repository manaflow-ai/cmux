public import CmuxCore

/// Factory seam through which ``RemoteProxyBroker`` obtains a tunnel for a
/// transport configuration.
///
/// The production conformer (``RemoteDaemonProxyTunnelProvider``) carries the
/// app-resolved localization strings and clock the concrete tunnel needs, so
/// the broker itself stays free of localization concerns. Tests substitute a
/// fake provider to exercise the broker's restart/backoff/teardown state
/// machine without real SSH transports.
public protocol RemoteProxyTunnelProviding: Sendable {
    /// Creates an unstarted tunnel for `configuration`.
    ///
    /// - Parameters:
    ///   - remotePath: Resolved remote path of the daemon binary.
    ///   - localPort: Loopback port the tunnel's proxy listener binds to.
    ///   - onFatalError: Invoked once when the started tunnel fails
    ///     irrecoverably (it has already stopped itself); may fire on any
    ///     queue.
    func makeTunnel(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        localPort: Int,
        onFatalError: @escaping @Sendable (String) -> Void
    ) -> any RemoteProxyTunneling
}
