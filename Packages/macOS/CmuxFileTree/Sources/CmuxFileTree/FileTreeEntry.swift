public import Foundation

/// One directory entry as a file tree provider reports it.
///
/// Entries are plain values so a listing can move between the provider, the
/// ``FileTreeEngine`` actor and the main actor without copying object graphs.
/// The absolute ``path`` is the stable identity of an entry: two listings that
/// report the same path describe the same row, and ``FileTreeChildrenDiff``
/// matches rows by it.
public struct FileTreeEntry: Sendable, Hashable {
    /// The last path component shown in the tree.
    public let name: String
    /// The absolute path on the provider's filesystem. Stable row identity.
    public let path: String
    /// The filesystem object kind.
    public let kind: FileTreeEntryKind
    /// The byte size for regular files, or `nil` when unknown or not a file.
    public let size: Int64?
    /// The modification time in seconds since 1970, or `nil` when unknown.
    public let modificationTime: TimeInterval?
    /// Whether the filesystem marks the entry hidden (the `UF_HIDDEN` flag).
    ///
    /// Dot-prefixed names are hidden regardless; see ``isHidden``.
    public let hasHiddenFlag: Bool

    /// Creates an entry.
    /// - Parameters:
    ///   - name: The last path component.
    ///   - path: The absolute path, used as the row identity.
    ///   - kind: The object kind.
    ///   - size: The byte size for regular files.
    ///   - modificationTime: Seconds since 1970, when the provider knows it.
    ///   - hasHiddenFlag: Whether the filesystem hides the entry with `UF_HIDDEN`.
    public init(
        name: String,
        path: String,
        kind: FileTreeEntryKind,
        size: Int64? = nil,
        modificationTime: TimeInterval? = nil,
        hasHiddenFlag: Bool = false
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modificationTime = modificationTime
        self.hasHiddenFlag = hasHiddenFlag
    }

    /// Whether the row can be expanded: a directory or a symlink to one.
    public var isDirectory: Bool {
        switch kind {
        case .directory, .symbolicLinkToDirectory: return true
        case .file, .symbolicLink, .other: return false
        }
    }

    /// Whether the entry is hidden unless the viewer shows hidden files.
    public var isHidden: Bool {
        hasHiddenFlag || name.hasPrefix(".")
    }

    /// The lowercase path extension, or an empty string.
    public var pathExtension: String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }
}

/// The filesystem object kind of a ``FileTreeEntry``.
public enum FileTreeEntryKind: Sendable, Hashable {
    /// A directory. Expandable.
    case directory
    /// A regular file.
    case file
    /// A symbolic link whose target is a directory. Expandable, like Finder aliases.
    case symbolicLinkToDirectory
    /// A symbolic link to a file, or a dangling link.
    case symbolicLink
    /// A socket, FIFO, device or other special file.
    case other
}
