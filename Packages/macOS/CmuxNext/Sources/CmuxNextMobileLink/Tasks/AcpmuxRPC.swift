public import CmuxMobileWire

/// One JSON-RPC 2.0 connection to this Mac's acpmux daemon (its unix socket),
/// as the phone's task runner uses it: requests, notifications, and the
/// daemon's messages that are not replies (session updates, permission
/// requests).
public protocol AcpmuxRPC: Sendable {
    func call(_ method: String, params: JSONValue) async throws -> JSONValue
    func notify(_ method: String, params: JSONValue) async throws
    /// Everything acpmux sends that is not a reply to `call`, in order.
    func messages() async -> AsyncStream<AcpmuxMessage>
    func close() async
}

/// A daemon message that is not a reply: a notification, or a request from
/// an agent (`session/request_permission`) that the Mac's own agent tab answers.
public struct AcpmuxMessage: Hashable, Sendable {
    public var method: String
    public var params: JSONValue
    public var isRequest: Bool

    public init(method: String, params: JSONValue, isRequest: Bool) {
        self.method = method
        self.params = params
        self.isRequest = isRequest
    }
}

/// An acpmux error reply or a broken connection.
public struct AcpmuxRPCError: Error, Hashable, Sendable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}
