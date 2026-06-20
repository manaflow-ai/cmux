/// The app-coupled command-dispatch seam for one accepted control-socket
/// client, driven per line by ``ControlClientConnectionHandler``.
///
/// The connection handler owns the transport pipeline — access-control,
/// password authentication, line framing, and the response write — but the
/// command bodies themselves reach into live application state (the event bus,
/// the v1/v2 command switch, workspace/window/browser graphs). Those stay in
/// the composition root, behind this seam, exactly where the legacy
/// `TerminalController.handleClient` loop called `isEventsStreamRequest`,
/// `handleEventsStreamRequest`, `processSocketLine`, and `publishSocketEvents`.
///
/// Threading: every method is invoked from the dedicated client-handler thread
/// the handler runs on, never the main actor or the listener queue. The legacy
/// loop ran these calls on the same per-connection `Thread`; implementations
/// must remain safe to call off-main and may block (the command bodies hop to
/// the main actor or wait on semaphores themselves).
public protocol ControlClientCommandDispatching: Sendable {
    /// Whether `line` is an `events.stream` subscription request, which the
    /// handler routes to ``handleEventsStream(line:socket:)`` instead of the
    /// one-shot command path.
    /// - Parameter line: The trimmed, non-empty client line.
    /// - Returns: `true` when the line opens the long-lived events stream.
    func isEventsStreamRequest(_ line: String) -> Bool

    /// Services an `events.stream` request to completion on the handler thread,
    /// writing the ack, replay, live events, and heartbeats to `socket` until
    /// the stream ends. The handler closes the connection after this returns.
    /// - Parameters:
    ///   - line: The trimmed `events.stream` request line.
    ///   - socket: The client descriptor to stream to.
    func handleEventsStream(line: String, socket: Int32)

    /// Processes one v1/v2 command line and returns the wire response (if any)
    /// plus the post-command authentication state.
    /// - Parameters:
    ///   - line: The trimmed, non-empty client line.
    ///   - authenticated: Whether the client has already authenticated.
    /// - Returns: The optional response line to write and the updated
    ///   authentication flag.
    func processCommandLine(_ line: String, authenticated: Bool)
        -> ControlClientCommandOutcome

    /// Publishes the command/response pair to the event bus after a response
    /// is produced, mirroring the legacy `publishSocketEvents` side effect.
    /// - Parameters:
    ///   - command: The trimmed client line that produced the response.
    ///   - response: The response written back to the client.
    func publishCommandEvents(command: String, response: String)
}

/// The result of dispatching one command line through
/// ``ControlClientCommandDispatching/processCommandLine(_:authenticated:)``.
///
/// Mirrors the legacy `SocketLineProcessingResult`: an optional response line
/// to write back and the authentication state to carry into the next line.
public struct ControlClientCommandOutcome: Sendable {
    /// The wire response to write to the client, or `nil` when the command
    /// produced no reply (e.g. a fire-and-forget notification).
    public let response: String?
    /// Whether the client is authenticated after this command.
    public let authenticated: Bool

    /// Creates a dispatch outcome.
    /// - Parameters:
    ///   - response: The response line to write, if any.
    ///   - authenticated: The post-command authentication state.
    public init(response: String?, authenticated: Bool) {
        self.response = response
        self.authenticated = authenticated
    }
}
