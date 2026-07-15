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
    /// Fetches the authoritative workspace state for this daemon slot.
    func getRuntimeState() throws -> RemoteRuntimeStateDocument?
    /// Replaces the authoritative workspace state for this daemon slot.
    func putRuntimeState(
        schemaVersion: Int,
        state: Data,
        expectedRevision: UInt64?
    ) throws -> RemoteRuntimeStateDocument
    /// Subscribes to authoritative workspace-state changes.
    func subscribeRuntimeState(
        queue: DispatchQueue,
        onDocument: @escaping @Sendable (RemoteRuntimeStateDocument) -> Void
    ) throws -> RemoteRuntimeStateDocument?
}

extension RemoteDaemonRPCClient: RemoteDaemonTunnelRPCClient {}
