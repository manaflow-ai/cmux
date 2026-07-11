import Foundation

/// Captures the stable identity inputs for a transcript file.
public struct JournalIdentity: Hashable, Sendable {
    /// The transcript path.
    public let path: String
    /// An adapter-supplied inode-like token.
    public let inodeLikeToken: String
    /// Whether the file head has been truncated or compacted.
    public let headTruncated: Bool

    /// Creates a journal identity value.
    /// - Parameters:
    ///   - path: The transcript path.
    ///   - inodeLikeToken: The inode-like token.
    ///   - headTruncated: Whether the file head was truncated.
    public init(path: String, inodeLikeToken: String, headTruncated: Bool) {
        self.path = path
        self.inodeLikeToken = inodeLikeToken
        self.headTruncated = headTruncated
    }
}
