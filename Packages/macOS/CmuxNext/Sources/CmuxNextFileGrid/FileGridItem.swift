public import Foundation

/// One file a ``FileGridView`` shows: where it is, what it is, and the facts
/// the grid sorts by. A value; the listing that holds it owns no file handle.
///
/// Its identity is the file's path: the same path seen again (a rewrite, a
/// new modification date) is the same item with new facts.
public nonisolated struct FileGridItem: Sendable, Hashable, Identifiable {
    /// The file.
    public var url: URL
    /// Picture, movie or other file (from the extension).
    public var kind: FileGridMediaKind
    /// Size in bytes.
    public var size: Int64
    /// Last content modification date; the grid's newest-first order.
    public var modified: Date
    /// The id of the source (folder) the item was listed from.
    public var sourceID: String

    /// Makes an item.
    ///
    /// - Parameters:
    ///   - url: the file.
    ///   - kind: defaults to the kind its extension says.
    ///   - size: size in bytes.
    ///   - modified: last modification date.
    ///   - sourceID: the id of the folder it was listed from.
    public init(url: URL, kind: FileGridMediaKind? = nil, size: Int64, modified: Date, sourceID: String) {
        self.url = url
        self.kind = kind ?? FileGridMediaKind(url: url)
        self.size = size
        self.modified = modified
        self.sourceID = sourceID
    }

    /// The file's path: the item's identity.
    public var id: String { url.path }
    /// The file name with its extension.
    public var name: String { url.lastPathComponent }
}
