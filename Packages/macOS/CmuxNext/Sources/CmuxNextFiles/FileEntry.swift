public import Foundation

/// One item of a folder listing: what a Files row, tile or column cell shows.
///
/// A value snapshot read in one `getattrlistbulk` pass (``DirectoryLister``),
/// so a 100 000-item folder lists without a `stat` per item and without
/// touching the main actor. Rows and tiles receive these values, never the
/// model (the snapshot-boundary rule for list subtrees).
public struct FileEntry: Sendable, Hashable, Identifiable {
    /// The folder the item is in (shared by every entry of one listing).
    public let parent: URL
    /// The name on disk.
    public let name: String
    /// What the item is.
    public let kind: FileKind
    /// Size in bytes for files; 0 for folders (Finder shows "--").
    public let size: Int64
    /// Last content change.
    public let modified: Date
    /// Creation date.
    public let created: Date
    /// Hidden from the default listing: a dot name or the `UF_HIDDEN` flag.
    public let isHidden: Bool
    /// The precomputed Finder-order key of ``name`` (``FileNameSortKey``).
    public let sortKey: FileNameSortKey

    /// The item's file URL (``parent`` plus ``name``). Made on each call:
    /// hot loops over a listing compare ``name`` instead.
    public var url: URL { parent.appendingPathComponent(name, isDirectory: kind == .folder || kind == .package) }

    /// The name is the identity within one folder listing.
    public var id: String { name }

    /// The file extension, lowercased; empty for none.
    public var pathExtension: String { (name as NSString).pathExtension.lowercased() }

    /// True for a folder that opens in place (not a package such as an app).
    public var opensAsFolder: Bool { kind == .folder }

    /// Makes an entry.
    /// - Parameters:
    ///   - url: The item's file URL.
    ///   - kind: What the item is.
    ///   - size: Bytes for a file, 0 otherwise.
    ///   - modified: Last content change.
    ///   - created: Creation date. Defaults to `modified`.
    ///   - isHidden: Whether the item is hidden. Defaults to true for a dot name.
    public init(url: URL, kind: FileKind, size: Int64 = 0, modified: Date = .distantPast,
                created: Date? = nil, isHidden: Bool? = nil) {
        self.init(name: url.lastPathComponent, in: url.deletingLastPathComponent(), kind: kind, size: size,
                  modified: modified, created: created, isHidden: isHidden)
    }

    /// Makes an entry from a name in `parent` (the lister's fast path: no URL per item).
    public init(name: String, in parent: URL, kind: FileKind, size: Int64 = 0, modified: Date = .distantPast,
                created: Date? = nil, isHidden: Bool? = nil) {
        self.parent = parent
        self.name = name
        self.kind = kind
        self.size = size
        self.modified = modified
        self.created = created ?? modified
        self.isHidden = isHidden ?? name.hasPrefix(".")
        self.sortKey = FileNameSortKey(name)
    }

    public static func == (lhs: FileEntry, rhs: FileEntry) -> Bool {
        lhs.name == rhs.name && lhs.parent == rhs.parent && lhs.kind == rhs.kind && lhs.size == rhs.size
            && lhs.modified == rhs.modified && lhs.isHidden == rhs.isHidden
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(name) }
}
