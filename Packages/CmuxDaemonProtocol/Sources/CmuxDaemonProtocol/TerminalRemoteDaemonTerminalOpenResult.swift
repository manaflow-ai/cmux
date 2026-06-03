public import Foundation

/// The result of opening a PTY-backed terminal via ``DaemonRPCMethod/terminalOpen``.
///
/// Carries the daemon-minted session and attachment identifiers, the initial
/// read offset, and the grid the daemon will render at.
public struct TerminalRemoteDaemonTerminalOpenResult: Decodable, Equatable, Sendable {
    /// The session identifier.
    public let sessionID: String
    /// The attachment identifier for this client.
    public let attachmentID: String
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
    /// The byte offset at which subsequent reads should begin.
    public let offset: UInt64
    /// See ``TerminalRemoteDaemonSessionStatus/gridGeneration``.
    public let gridGeneration: UInt64?

    /// Creates a terminal-open result value.
    /// - Parameters:
    ///   - sessionID: The session identifier.
    ///   - attachmentID: The attachment identifier for this client.
    ///   - attachments: The per-attachment grid states.
    ///   - effectiveCols: The effective column count.
    ///   - effectiveRows: The effective row count.
    ///   - lastKnownCols: The most recently observed column count.
    ///   - lastKnownRows: The most recently observed row count.
    ///   - offset: The initial read offset.
    ///   - gridGeneration: The monotonic grid-change counter, if reported.
    public init(
        sessionID: String,
        attachmentID: String,
        attachments: [TerminalRemoteDaemonAttachmentStatus],
        effectiveCols: Int,
        effectiveRows: Int,
        lastKnownCols: Int,
        lastKnownRows: Int,
        offset: UInt64,
        gridGeneration: UInt64? = nil
    ) {
        self.sessionID = sessionID
        self.attachmentID = attachmentID
        self.attachments = attachments
        self.effectiveCols = effectiveCols
        self.effectiveRows = effectiveRows
        self.lastKnownCols = lastKnownCols
        self.lastKnownRows = lastKnownRows
        self.offset = offset
        self.gridGeneration = gridGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case attachmentID = "attachment_id"
        case attachments
        case effectiveCols = "effective_cols"
        case effectiveRows = "effective_rows"
        case lastKnownCols = "last_known_cols"
        case lastKnownRows = "last_known_rows"
        case offset
        case gridGeneration = "grid_generation"
    }
}
