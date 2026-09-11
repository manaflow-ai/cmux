import Foundation

/// A review comment left on a line range in the diff viewer.
///
/// `endLine` (on `side`) is the anchor line the comment renders under;
/// `lineText` is that line's content at save time so the comment can be
/// re-anchored when the same diff is regenerated with shifted line numbers.
public struct DiffComment: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var filePath: String
    public var side: String
    public var startLine: Int
    public var endLine: Int
    public var endSide: String?
    public var lineText: String
    public var message: String
    /// Formatted text block appended to a TextBox submission when the
    /// workspace's pending pool is consumed.
    public var submissionText: String?
    /// Set when a TextBox submission delivered this comment to an agent;
    /// consumed comments never re-enter the pending pool.
    public var consumedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    /// Creates a comment. Callers supply the anchor (`side`, `startLine`,
    /// `endLine`, `lineText`) captured when the comment was saved.
    public init(
        id: UUID,
        filePath: String,
        side: String,
        startLine: Int,
        endLine: Int,
        endSide: String? = nil,
        lineText: String,
        message: String,
        submissionText: String? = nil,
        consumedAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.filePath = filePath
        self.side = side
        self.startLine = startLine
        self.endLine = endLine
        self.endSide = endSide
        self.lineText = lineText
        self.message = message
        self.submissionText = submissionText
        self.consumedAt = consumedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
