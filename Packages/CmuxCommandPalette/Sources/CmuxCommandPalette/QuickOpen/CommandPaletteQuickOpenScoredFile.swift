public import Foundation

/// A scored Quick Open file-search candidate.
public struct CommandPaletteQuickOpenScoredFile: Sendable {
    /// The matched file or directory URL.
    public let url: URL
    /// The fuzzy-match score.
    public let score: Int
    /// The recursive directory depth where the item was found.
    public let depth: Int

    /// Creates a scored Quick Open file-search candidate.
    public init(url: URL, score: Int, depth: Int) {
        self.url = url
        self.score = score
        self.depth = depth
    }
}
