public import CmuxRemoteDaemon
public import Foundation

/// The narrow "open/write/attach/close a named byte stream" surface
/// ``RemoteDaemonProxySession`` needs from its backend. Deliberately excludes
/// PTY lifecycle and daemon transport control (`RemoteDaemonTunnelRPCClient`'s
/// other requirements) so a non-daemon backend — for example a SOCKS5 client
/// dialing out through an `ssh -D` dynamic forward — can conform without
/// having to fake unrelated daemon RPCs.
public protocol RemoteProxyStreamOpening {
    /// Opens a proxy stream to `host:port`, returning its stream ID.
    func openStream(host: String, port: Int, timeoutMs: Int) throws -> String
    /// Writes bytes to an open proxy stream.
    func writeStream(streamID: String, data: Data) throws
    /// Subscribes to ordered events for an open proxy stream.
    func attachStream(
        streamID: String,
        queue: DispatchQueue,
        onEvent: @escaping (RemoteDaemonStreamEvent) -> Void
    ) throws
    /// Closes a proxy stream.
    func closeStream(streamID: String)
}
