public import CmuxRemoteDaemon
public import Foundation

extension RemoteDaemonProxyTunnel {
    /// Returns metadata for one path through the tunnel's capability-gated RPC client.
    ///
    /// - Parameter path: Absolute path on the remote host.
    /// - Returns: The remote filesystem metadata snapshot.
    /// - Throws: A tunnel-readiness, RPC, capability, or filesystem error.
    public func statFile(path: String) throws -> RemoteDaemonFileStat {
        try queue.sync {
            guard let rpcClient, !isStopped else {
                throw NSError(domain: "cmux.remote.files", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon tunnel is not ready",
                ])
            }
            return try rpcClient.statFile(path: path)
        }
    }

    /// Reads one bounded regular file through the tunnel's RPC client.
    ///
    /// - Parameter path: Absolute regular-file path on the remote host.
    /// - Returns: The bounded remote file contents.
    /// - Throws: A tunnel-readiness, RPC, capability, bounds, or filesystem error.
    public func readFile(path: String) throws -> Data {
        try queue.sync {
            guard let rpcClient, !isStopped else {
                throw NSError(domain: "cmux.remote.files", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon tunnel is not ready",
                ])
            }
            return try rpcClient.readFile(path: path)
        }
    }
}
