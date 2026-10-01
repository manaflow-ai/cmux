public import CmuxConversation

/// A JSON-RPC notification from acpmux.
public struct AcpmuxNotification: Hashable, Sendable {
    /// The method, such as `session/update` or `_acpmux/event`.
    public var method: String
    /// The parameters.
    public var params: JSONValue

    /// Creates a notification.
    /// - Parameters:
    ///   - method: The method.
    ///   - params: The parameters.
    public init(method: String, params: JSONValue) {
        self.method = method
        self.params = params
    }

    /// The session it concerns, when it names one.
    public var sessionID: String? { params["sessionId"]?.stringValue }
}
