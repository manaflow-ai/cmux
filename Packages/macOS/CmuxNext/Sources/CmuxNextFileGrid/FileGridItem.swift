public import Foundation

/// One file a ``FileGridView`` shows: where it is, what it is, and the facts
/// the grid sorts by. A value; the listing that holds it owns no file handle.
///
/// Its identity is the file's path: the same path seen again (a rewrite, a
/// new modification date) is the same item with new facts.
public nonisolated struct FileGridItem: Sendable, Hashable, Identifiable {
    /// The file.
    public var url: URL { didSet { id = url.path } }
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
        id = url.path
        self.kind = kind ?? FileGridMediaKind(url: url)
        self.size = size
        self.modified = modified
        self.sourceID = sourceID
    }

    /// The file's path: the item's identity, kept when `url` is set (`URL.path` percent-decodes the URL on every read:
    /// `FileGridView.show` reads each item's id several times, a 3.5 s main-thread hang on a large Screenshots folder,
    /// NIGHTLY hang log 2026-10-30T06:10).
    public private(set) var id: String
    /// The file name with its extension.
    public var name: String { url.lastPathComponent }
}
