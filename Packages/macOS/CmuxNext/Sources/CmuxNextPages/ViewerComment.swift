public import Foundation

/// One comment the user left on a viewer file's lines (Comment… on selected text,
/// viewer-comments-DESIGN.md "Comments in the viewer"): kept with the file and shown as a margin
/// marker that opens its card.
public nonisolated struct ViewerComment: Codable, Hashable, Sendable {
    /// Stable id: the marker's key and what Delete names.
    public var id: String
    /// The first commented source line, 1-based.
    public var startLine: Int
    /// The last commented source line, 1-based, at least ``startLine``.
    public var endLine: Int
    /// The selected text when the comment was made.
    public var quoted: String
    /// What the user wrote.
    public var comment: String

    /// A comment on `startLine...endLine`.
    public init(id: String, startLine: Int, endLine: Int, quoted: String, comment: String) {
        self.id = id
        self.startLine = startLine
        self.endLine = endLine
        self.quoted = quoted
        self.comment = comment
    }
}
