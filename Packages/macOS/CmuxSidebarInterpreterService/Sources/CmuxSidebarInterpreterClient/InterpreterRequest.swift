import CmuxSwiftRender

/// A request sent from the host to the out-of-process interpreter worker:
/// interpret `source` against `state` and return the resulting ``RenderNode``.
///
/// `id` correlates the response to this request so the host can match replies
/// even though the worker is a separate process and the channel is a single
/// ordered byte stream.
public struct InterpreterRequest: Codable, Sendable {
    /// Monotonic per-client identifier the matching ``InterpreterResponse`` echoes.
    public let id: UInt64
    /// The untrusted Swift-subset sidebar source to interpret.
    public let source: String
    /// The live, read-only data context the interpreter binds identifiers to.
    public let state: [String: SwiftValue]

    public init(id: UInt64, source: String, state: [String: SwiftValue]) {
        self.id = id
        self.source = source
        self.state = state
    }
}
