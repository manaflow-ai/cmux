public import Foundation

/// A file's viewer comments as the page and the store keep them: `{"v":1,"comments":[...]}`,
/// oldest first, bounded (``limit`` comments, long texts cut) so the value fits an extended attribute.
public nonisolated struct ViewerCommentList: Hashable, Sendable {
    /// The most comments kept per file; adding past it drops the oldest.
    public static let limit = 100
    /// The longest quoted text kept, in characters.
    public static let quotedLimit = 1000
    /// The longest comment kept, in characters.
    public static let commentLimit = 2000

    /// The comments, oldest first.
    public private(set) var comments: [ViewerComment] = []

    /// An empty list.
    public init() {}

    /// The list stored as `data`; nil when it is not one.
    public init?(data: Data) {
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.v == 1 else { return nil }
        comments = Array(stored.comments.suffix(Self.limit))
    }

    /// The stored form.
    public var data: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(Stored(v: 1, comments: comments))) ?? Data()
    }

    /// Adds a comment for `quote` (which must have lines and a comment); false when it has neither.
    @discardableResult
    public mutating func add(_ quote: ChatQuote, id: String) -> Bool {
        let text = quote.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lines = quote.lines, !text.isEmpty else { return false }
        comments.append(ViewerComment(id: id, startLine: lines.lowerBound, endLine: lines.upperBound,
                                      quoted: String(quote.quoted.prefix(Self.quotedLimit)), comment: String(text.prefix(Self.commentLimit))))
        if comments.count > Self.limit { comments.removeFirst(comments.count - Self.limit) }
        return true
    }

    /// Removes the comment `id`; false when there is none.
    @discardableResult
    public mutating func remove(_ id: String) -> Bool {
        guard let index = comments.firstIndex(where: { $0.id == id }) else { return false }
        comments.remove(at: index)
        return true
    }

    /// Drops the oldest comments until the stored form is at most `bytes` long.
    public mutating func trim(toBytes bytes: Int) {
        while !comments.isEmpty, data.count > bytes { comments.removeFirst() }
    }

    nonisolated private struct Stored: Codable {
        var v: Int
        var comments: [ViewerComment]
    }
}
