/// The fields of an `action.*` interval's begin message, handed to the log system unformatted.
///
/// ``Signposter`` interpolates each field into the
/// `OSLogMessage` itself, so the number is formatted (and the text assembled) only when a
/// recorder reads the signpost, not on the action's turn.
public nonisolated struct ActionSignpostMessage: Sendable, Hashable {
    /// The action's id (`ActionID.rawValue`).
    public var id: String
    /// Who started the run (`ActionOrigin.rawValue`: `user`, `cli`, `mcp`, ...).
    public var origin: String
    /// The age in milliseconds of the OS input event AppKit is dispatching for a `user` run, or
    /// -1 when the run has no such event (a socket, CLI, MCP, page or remote run, or a user run
    /// outside an event's dispatch).
    public var inputAgeMilliseconds: Double

    /// A message for one action run.
    ///
    /// - Parameters:
    ///   - id: The action's id.
    ///   - origin: Who started the run.
    ///   - inputAgeMilliseconds: The dispatched input event's age, or -1 without one.
    public init(id: String, origin: String, inputAgeMilliseconds: Double) {
        self.id = id
        self.origin = origin
        self.inputAgeMilliseconds = inputAgeMilliseconds
    }
}
