public import Foundation

/// The set of sessions returned by ``DaemonRPCMethod/sessionList``.
public struct TerminalRemoteDaemonSessionListResult: Decodable, Equatable, Sendable {
    /// The sessions, in daemon-defined order.
    public let sessions: [TerminalRemoteDaemonSessionListEntry]

    /// Creates a session-list result value.
    /// - Parameter sessions: The sessions, in daemon-defined order.
    public init(sessions: [TerminalRemoteDaemonSessionListEntry]) {
        self.sessions = sessions
    }
}
