/// A source that knows its connection state (optional next to
/// `TerminalByteSource`; the screen shows a banner only for such sources).
public protocol TerminalConnectionReporting: Sendable {
    /// The current state first, then every change.
    func connectionStates() async -> AsyncStream<TerminalConnectionState>
}
