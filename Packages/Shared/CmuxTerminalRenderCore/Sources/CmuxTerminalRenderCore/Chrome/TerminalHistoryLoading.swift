/// A source that can fetch scrollback older than what it restored
/// (optional next to `TerminalByteSource`; the cmux host link).
public protocol TerminalHistoryLoading: Sendable {
    /// Asks for the page before the oldest history this viewer holds.
    func loadOlderHistory() async
    /// The current state first, then every change.
    func historyStates() async -> AsyncStream<TerminalHistoryState>
}
