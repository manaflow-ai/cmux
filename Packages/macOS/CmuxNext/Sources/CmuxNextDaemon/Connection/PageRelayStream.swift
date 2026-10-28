/// The daemon process and page-relay connection a page stream lives on. A stream ends with its
/// connection (p05-ipc design 3.1), so a reconnect, or a restarted daemon on the same socket,
/// is another epoch, and a stream of an old epoch never takes a call again. Chrome does the same
/// with a channel-associated interface: it is bound to one `IPC::ChannelMojo` and dies with it
/// (ipc/ipc_mojo_bootstrap.cc); a restarted renderer gets new bindings.
public struct PageRelayEpoch: Hashable, Sendable {
    public var pid: Int32
    public var generation: DaemonGeneration
    /// The connection's `client-hello` id: new on every connect, and what a confirmation token is bound to.
    public var connectionID: String

    public init(pid: Int32, generation: DaemonGeneration, connectionID: String) {
        self.pid = pid
        self.generation = generation
        self.connectionID = connectionID
    }

    /// Whether this epoch's daemon is the process `pid` of boot `generation`.
    public func serves(pid: Int32, generation: DaemonGeneration) -> Bool {
        self.pid == pid && self.generation == generation
    }
}

/// One page's stream on a daemon's page-relay connection: the daemon judges
/// every request on it with the stream's origin `page:<id>`, fixed when the stream opened. There
/// is no send without a stream, so no page call can go out untagged.
public protocol PageRelayStream: AnyObject, Sendable {
    /// The page id the stream serves (`home-channels`).
    var page: String { get }
    var epoch: PageRelayEpoch { get }
    /// False once the stream ended: closed, or its connection lost or replaced.
    var isOpen: Bool { get async }
    /// One `cmux.protocol/2` op on this stream; `origin` is the page's claim (`page`, or `user`
    /// with a confirmation token).
    func send(operation: String, params: [String: JSONValue], idempotencyKey: String?,
              origin: JSONValue) async throws -> JSONValue
    /// Ends the stream; later sends fail with `DaemonError.connectionClosed`.
    func close() async
}

/// A daemon's page-relay connection as its pages see it: it opens page streams.
public protocol PageRelayStreamOpening: AnyObject, Sendable {
    /// Opens a stream for `page` (a page-router.json page id); it is ready for calls on return.
    func openStream(page: String) async throws -> any PageRelayStream
}
