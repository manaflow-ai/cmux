/// A decoded v2 control-protocol request envelope (was `V2SocketRequest`).
///
/// The wire form is a single JSON object line: `{"id":…,"method":…,"params":…}`.
/// `id` is echoed back verbatim in the response (`null` when absent), `method`
/// selects the command, and `params` carries the command arguments.
public struct ControlRequest: Sendable {
    /// The caller-supplied request id, echoed in the response. `nil` when the
    /// request omitted it (fire-and-forget notification semantics for some
    /// methods, e.g. `feed.push`).
    public let id: JSONValue?
    /// The non-empty, whitespace-trimmed method name.
    public let method: String
    /// The command parameters. Missing or non-object `params` decode as empty.
    public let params: [String: JSONValue]

    /// Creates a request envelope.
    ///
    /// - Parameters:
    ///   - id: The caller-supplied request id, if any.
    ///   - method: The trimmed method name.
    ///   - params: The command parameters.
    public init(id: JSONValue?, method: String, params: [String: JSONValue]) {
        self.id = id
        self.method = method
        self.params = params
    }
}
