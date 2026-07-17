internal import CmuxRemoteDaemon
internal import Foundation

/// Complete daemon RPC surface owned by one proxy tunnel runtime.
protocol RemoteDaemonTunnelRPCClient: RemotePTYLifecycleRPCClient {
    /// Stops the underlying daemon transport.
    func stop()
    /// Opens a daemon-side TCP proxy stream.
    func openStream(host: String, port: Int, timeoutMs: Int) throws -> String
    /// Writes bytes to a daemon-side TCP proxy stream.
    func writeStream(streamID: String, data: Data) throws
    /// Subscribes to ordered events for a daemon-side TCP proxy stream.
    func attachStream(
        streamID: String,
        queue: DispatchQueue,
        onEvent: @escaping (RemoteDaemonStreamEvent) -> Void
    ) throws
    /// Closes a daemon-side TCP proxy stream.
    func closeStream(streamID: String)
    /// Returns metadata for one remote path.
    func statFile(path: String, timeout: TimeInterval) throws -> RemoteDaemonFileStat
    /// Reads one bounded remote regular file.
    func readFile(path: String, timeout: TimeInterval) throws -> Data
}

extension RemoteDaemonTunnelRPCClient {
    func statFile(path: String, timeout: TimeInterval) throws -> RemoteDaemonFileStat {
        throw NSError(domain: "cmux.remote.files", code: 9, userInfo: [
            NSLocalizedDescriptionKey: "remote filesystem access is unavailable",
        ])
    }

    func readFile(path: String, timeout: TimeInterval) throws -> Data {
        throw NSError(domain: "cmux.remote.files", code: 10, userInfo: [
            NSLocalizedDescriptionKey: "remote filesystem access is unavailable",
        ])
    }
}

extension RemoteDaemonRPCClient: RemoteDaemonTunnelRPCClient {}
