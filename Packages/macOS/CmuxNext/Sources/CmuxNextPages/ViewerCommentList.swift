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
        nil
    }

    /// The stored form.
    public var data: Data { Data() }

    /// Adds a comment for `quote` (which must have lines and a comment); false when it has neither.
    @discardableResult
    public mutating func add(_ quote: ChatQuote, id: String) -> Bool {
        false
    }

    /// Removes the comment `id`; false when there is none.
    @discardableResult
    public mutating func remove(_ id: String) -> Bool {
        false
    }
}
