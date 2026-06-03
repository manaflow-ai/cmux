public import Foundation

/// A single session as reported by ``DaemonRPCMethod/sessionList``.
///
/// Carried inside ``TerminalRemoteDaemonSessionListResult``.
public struct TerminalRemoteDaemonSessionListEntry: Decodable, Equatable, Sendable {
    /// The session identifier.
    public let sessionID: String
    /// The number of clients attached to the session.
    public let attachmentCount: Int
    /// The effective column count the daemon renders at.
    public let effectiveCols: Int
    /// The effective row count the daemon renders at.
    public let effectiveRows: Int

    /// Creates a session-list entry value.
    /// - Parameters:
    ///   - sessionID: The session identifier.
    ///   - attachmentCount: The number of attached clients.
    ///   - effectiveCols: The effective column count.
    ///   - effectiveRows: The effective row count.
    public init(
        sessionID: String,
        attachmentCount: Int,
        effectiveCols: Int,
        effectiveRows: Int
    ) {
        self.sessionID = sessionID
        self.attachmentCount = attachmentCount
        self.effectiveCols = effectiveCols
        self.effectiveRows = effectiveRows
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case attachmentCount = "attachment_count"
        case effectiveCols = "effective_cols"
        case effectiveRows = "effective_rows"
    }
}
