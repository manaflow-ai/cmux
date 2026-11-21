internal import CmuxRemoteDaemon
internal import Foundation

/// Complete daemon RPC surface owned by one proxy tunnel runtime.
protocol RemoteDaemonTunnelRPCClient: RemotePTYLifecycleRPCClient, RemoteProxyStreamOpening {
    /// Stops the underlying daemon transport.
    func stop()
}

extension RemoteDaemonRPCClient: RemoteDaemonTunnelRPCClient {}
