public import CmuxRemoteDaemon
public import Dispatch
public import Foundation

extension RemoteDaemonProxyTunnel {
    /// Returns metadata for one path through the tunnel's capability-gated RPC client.
    ///
    /// - Parameters:
    ///   - path: Absolute path on the remote host.
    ///   - deadline: Monotonic deadline shared with the originating file operation.
    /// - Returns: The remote filesystem metadata snapshot.
    /// - Throws: A tunnel-readiness, RPC, capability, or filesystem error.
    public func statFile(path: String, deadline: DispatchTime) throws -> RemoteDaemonFileStat {
        let client = try queue.sync {
            guard let rpcClient, !isStopped else {
                throw NSError(domain: "cmux.remote.files", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon tunnel is not ready",
                ])
            }
            return rpcClient
        }
        return try client.statFile(path: path, timeout: Self.remainingFileRPCTimeout(until: deadline))
    }

    /// Reads one bounded regular file through the tunnel's RPC client.
    ///
    /// - Parameters:
    ///   - path: Absolute regular-file path on the remote host.
    ///   - deadline: Monotonic deadline shared with the originating file operation.
    /// - Returns: The bounded remote file contents.
    /// - Throws: A tunnel-readiness, RPC, capability, bounds, or filesystem error.
    public func readFile(path: String, deadline: DispatchTime) throws -> Data {
        let client = try queue.sync {
            guard let rpcClient, !isStopped else {
                throw NSError(domain: "cmux.remote.files", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon tunnel is not ready",
                ])
            }
            return rpcClient
        }
        return try client.readFile(path: path, timeout: Self.remainingFileRPCTimeout(until: deadline))
    }

    private static func remainingFileRPCTimeout(until deadline: DispatchTime) throws -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline.uptimeNanoseconds > now else {
            throw NSError(domain: "cmux.remote.files", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "timed out waiting for remote file operation",
            ])
        }
        return Double(deadline.uptimeNanoseconds - now) / 1_000_000_000
    }
}
