/// How a terminal's connection to its owner stands, for the screen's
/// banner (d1-terminal-ux.md section 3). Sources that know (the cmux host
/// link, SSH) report it through `TerminalConnectionReporting`.
public enum TerminalConnectionState: Sendable, Hashable {
    /// The first connect is under way.
    case connecting
    case connected
    /// The connection dropped; the source is getting it back (input sent
    /// meanwhile is retained up to the channel budget, nothing else queues).
    case reconnecting(attempt: Int)
    /// No connection and no attempt running.
    case offline
}
