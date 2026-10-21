public import Foundation

/// A name already taken in the destination folder.
public struct FileConflict: Sendable, Hashable {
    /// The item being copied or moved.
    public let source: URL
    /// The item already there.
    public let existing: URL
    /// Both are folders (Finder offers Merge).
    public let bothFolders: Bool

    /// Makes a conflict.
    public init(source: URL, existing: URL, bothFolders: Bool) {
        self.source = source
        self.existing = existing
        self.bothFolders = bothFolders
    }
}
