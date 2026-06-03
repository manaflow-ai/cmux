public import Foundation

/// The full grid state for a daemon session across all attachments.
///
/// Returned by session lifecycle RPCs (`session.open`, `session.attach`,
/// `session.resize`, `session.detach`) to report the effective (max) grid the
/// daemon will render at, plus the last-known grid and every attachment's
/// requested size.
public struct TerminalRemoteDaemonSessionStatus: Decodable, Equatable, Sendable {
    /// The session identifier.
    public let sessionID: String
    /// The per-attachment grid states.
    public let attachments: [TerminalRemoteDaemonAttachmentStatus]
    /// The effective column count the daemon renders at.
    public let effectiveCols: Int
    /// The effective row count the daemon renders at.
    public let effectiveRows: Int
    /// The most recently observed column count.
    public let lastKnownCols: Int
    /// The most recently observed row count.
    public let lastKnownRows: Int
    /// Monotonic counter bumped by the daemon on every effective-size change.
    ///
    /// Optional for back-compat with older daemons; clients that need strict
    /// ordering should treat `nil` as "not reported / always apply the first one seen".
    public let gridGeneration: UInt64?

    /// Creates a session status value.
    /// - Parameters:
    ///   - sessionID: The session identifier.
    ///   - attachments: The per-attachment grid states.
    ///   - effectiveCols: The effective column count.
    ///   - effectiveRows: The effective row count.
    ///   - lastKnownCols: The most recently observed column count.
    ///   - lastKnownRows: The most recently observed row count.
    ///   - gridGeneration: The monotonic grid-change counter, if reported.
    public init(
        sessionID: String,
        attachments: [TerminalRemoteDaemonAttachmentStatus],
        effectiveCols: Int,
        effectiveRows: Int,
        lastKnownCols: Int,
        lastKnownRows: Int,
        gridGeneration: UInt64? = nil
    ) {
        self.sessionID = sessionID
        self.attachments = attachments
        self.effectiveCols = effectiveCols
        self.effectiveRows = effectiveRows
        self.lastKnownCols = lastKnownCols
        self.lastKnownRows = lastKnownRows
        self.gridGeneration = gridGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case attachments
        case effectiveCols = "effective_cols"
        case effectiveRows = "effective_rows"
        case lastKnownCols = "last_known_cols"
        case lastKnownRows = "last_known_rows"
        case gridGeneration = "grid_generation"
    }
}
