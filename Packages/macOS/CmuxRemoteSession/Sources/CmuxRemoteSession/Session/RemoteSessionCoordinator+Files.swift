public import CmuxRemoteDaemon
public import Foundation

extension RemoteSessionCoordinator {
    /// Returns metadata for one remote path. Blocks only the calling worker
    /// thread while the controller and tunnel queues serialize the RPC.
    ///
    /// - Parameters:
    ///   - path: Absolute path on the remote host.
    ///   - timeout: Maximum time to wait for controller and RPC completion.
    /// - Returns: The remote filesystem metadata snapshot.
    /// - Throws: A coordinator-readiness, timeout, RPC, capability, or filesystem error.
    public func statRemoteFile(
        path: String,
        timeout: TimeInterval = 8.0
    ) throws -> RemoteDaemonFileStat {
        try runOnControllerQueue(timeout: timeout) {
            guard self.daemonReady, self.proxyLease != nil else {
                throw NSError(domain: "cmux.remote.files", code: 7, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon is not ready",
                ])
            }
            return try self.proxyBroker.statFile(
                configuration: self.configuration,
                path: path
            )
        }
    }

    /// Reads one bounded regular file from the remote host.
    ///
    /// - Parameters:
    ///   - path: Absolute regular-file path on the remote host.
    ///   - timeout: Maximum time to wait for controller and RPC completion.
    /// - Returns: The bounded remote file contents.
    /// - Throws: A coordinator-readiness, timeout, RPC, capability, bounds, or filesystem error.
    public func readRemoteFile(
        path: String,
        timeout: TimeInterval = 8.0
    ) throws -> Data {
        try runOnControllerQueue(timeout: timeout) {
            guard self.daemonReady, self.proxyLease != nil else {
                throw NSError(domain: "cmux.remote.files", code: 8, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon is not ready",
                ])
            }
            return try self.proxyBroker.readFile(
                configuration: self.configuration,
                path: path
            )
        }
    }
}
