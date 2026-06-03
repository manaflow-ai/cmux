public import Foundation

/// The per-attachment grid state for a daemon session.
///
/// Each client attached to a session reports its own desired grid, and the
/// daemon echoes all attachments back inside a ``TerminalRemoteDaemonSessionStatus``
/// so clients can reason about the effective (max) grid.
public struct TerminalRemoteDaemonAttachmentStatus: Decodable, Equatable, Sendable {
    /// The attachment identifier.
    public let attachmentID: String
    /// The attachment's requested column count.
    public let cols: Int
    /// The attachment's requested row count.
    public let rows: Int
    /// The attachment's reported mode, if any.
    public let mode: String?
    /// The time the attachment was last updated, if reported.
    public let updatedAt: Date?

    /// Creates an attachment status value.
    /// - Parameters:
    ///   - attachmentID: The attachment identifier.
    ///   - cols: The requested column count.
    ///   - rows: The requested row count.
    ///   - mode: The reported mode, if any.
    ///   - updatedAt: The last-updated time, if reported.
    public init(
        attachmentID: String,
        cols: Int,
        rows: Int,
        mode: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.attachmentID = attachmentID
        self.cols = cols
        self.rows = rows
        self.mode = mode
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case attachmentID = "attachment_id"
        case cols
        case rows
        case mode
        case updatedAt = "updated_at"
    }
}
