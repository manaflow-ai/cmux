public import Foundation

/// What Get Info (Cmd+I) shows about one item.
public struct FileInfo: Sendable, Equatable {
    /// The item.
    public let url: URL
    /// Its name.
    public var name: String { url.lastPathComponent }
    /// The folder it is in ("Where").
    public var folder: URL { url.deletingLastPathComponent() }
    /// The system's kind text ("PDF document", "Folder").
    public let kind: String
    /// Logical size in bytes; nil for folders (see ``FileInfoReader/folderSize(of:)``).
    public let size: Int64?
    /// Bytes on disk; nil for folders.
    public let allocatedSize: Int64?
    /// Created.
    public let created: Date?
    /// Modified.
    public let modified: Date?
    /// Last opened (content access date).
    public let lastOpened: Date?
    /// POSIX mode bits (`0o644`).
    public let permissions: Int
    /// The owner's account name.
    public let owner: String?
    /// The Locked box (`UF_IMMUTABLE`).
    public let isLocked: Bool
    /// The Hide extension box.
    public let isExtensionHidden: Bool
    /// What kind of item it is.
    public let fileKind: FileKind

    /// Makes a record (``FileInfoReader`` reads real ones).
    public init(url: URL, kind: String, size: Int64?, allocatedSize: Int64?, created: Date?, modified: Date?,
                lastOpened: Date?, permissions: Int, owner: String?, isLocked: Bool, isExtensionHidden: Bool,
                fileKind: FileKind) {
        self.url = url
        self.kind = kind
        self.size = size
        self.allocatedSize = allocatedSize
        self.created = created
        self.modified = modified
        self.lastOpened = lastOpened
        self.permissions = permissions
        self.owner = owner
        self.isLocked = isLocked
        self.isExtensionHidden = isExtensionHidden
        self.fileKind = fileKind
    }
}
