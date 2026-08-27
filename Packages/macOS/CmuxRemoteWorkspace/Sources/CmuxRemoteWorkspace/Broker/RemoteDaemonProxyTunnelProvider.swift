public import CmuxCore
public import CmuxRemoteDaemon

/// Production ``RemoteProxyTunnelProviding``: constructs real
/// ``RemoteDaemonProxyTunnel`` instances, carrying the app-resolved daemon and
/// PTY-bridge strings (localization stays app-side) and the retry clock the
/// tunnel forwards to its PTY bridge servers.
public struct RemoteDaemonProxyTunnelProvider: RemoteProxyTunnelProviding {
    private let strings: RemoteDaemonStrings
    private let ptyBridgeStrings: any RemotePTYBridgeStrings
    private let clock: any RemoteProxyRetryClock

    /// Creates the provider.
    ///
    /// - Parameters:
    ///   - strings: App-resolved daemon error strings passed to each tunnel's
    ///     RPC client.
    ///   - ptyBridgeStrings: App-resolved PTY attach error strings passed to
    ///     each tunnel's PTY bridge servers.
    ///   - clock: Sleep seam forwarded to the tunnels (production default:
    ///     the continuous clock).
    public init(
        strings: RemoteDaemonStrings,
        ptyBridgeStrings: any RemotePTYBridgeStrings,
        clock: any RemoteProxyRetryClock = SystemRemoteProxyRetryClock()
    ) {
        self.strings = strings
        self.ptyBridgeStrings = ptyBridgeStrings
        self.clock = clock
    }

    /// Creates an unstarted ``RemoteDaemonProxyTunnel`` for `configuration`.
    public func makeTunnel(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        localPort: Int,
        onFatalError: @escaping @Sendable (String) -> Void
    ) -> any RemoteProxyTunneling {
        RemoteDaemonProxyTunnel(
            configuration: configuration,
            remotePath: remotePath,
            localPort: localPort,
            strings: strings,
            ptyBridgeStrings: ptyBridgeStrings,
            clock: clock,
            onFatalError: onFatalError
        )
    }
}
