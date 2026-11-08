/// One immediate child entry in a Mac-hosted artifact directory.
public struct ChatArtifactDirectoryEntry: Sendable, Equatable, Codable, Identifiable {
    /// Entry display name relative to the listed directory.
    public let name: String
    /// Whether this entry is a directory.
    public let isDirectory: Bool
    /// Raw byte size for files, or the filesystem-reported size for directories.
    public let size: Int64
    /// The entry preview category.
    public let kind: ChatArtifactKind

    /// Stable identity for SwiftUI lists.
    public var id: String { name }

    /// Creates a directory entry.
    ///
    /// - Parameters:
    ///   - name: Entry display name relative to the listed directory.
    ///   - isDirectory: Whether this entry is a directory.
    ///   - size: Raw byte size or filesystem-reported directory size.
    ///   - kind: Preview category.
    public init(name: String, isDirectory: Bool, size: Int64, kind: ChatArtifactKind) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case isDirectory = "is_directory"
        case size
        case kind
    }
}
