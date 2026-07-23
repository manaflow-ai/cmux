public import Foundation

/// Immutable filesystem tree node projected to sidebar rows.
public struct ArtifactNode: Identifiable, Equatable, Sendable {
    /// Node identity, equal to its project-relative path.
    public let id: String
    /// Basename shown in the tree.
    public let name: String
    /// Path relative to the project's `.cmux` filesystem.
    public let relativePath: String
    /// Absolute local path used by open, reveal, copy, and drag actions.
    public let absolutePath: String
    /// Whether this node is an ordinary directory.
    public let isDirectory: Bool
    /// Preview classification for files.
    public let fileKind: ArtifactFileKind?
    /// File byte size when available.
    public let size: Int64?
    /// Filesystem modification time when available.
    public let modifiedAt: Date?
    /// Eager child snapshot for directories.
    public let children: [ArtifactNode]

    /// Creates an immutable artifact tree node.
    ///
    /// - Parameters:
    ///   - id: Stable node identity.
    ///   - name: Basename shown in the tree.
    ///   - relativePath: Path relative to the project `.cmux` filesystem.
    ///   - absolutePath: Absolute local path.
    ///   - isDirectory: Whether the node is a directory.
    ///   - fileKind: Preview classification for a file.
    ///   - size: File byte size when known.
    ///   - modifiedAt: Filesystem modification time when known.
    ///   - children: Eager child snapshot for a directory.
    public init(
        id: String,
        name: String,
        relativePath: String,
        absolutePath: String,
        isDirectory: Bool,
        fileKind: ArtifactFileKind?,
        size: Int64?,
        modifiedAt: Date?,
        children: [ArtifactNode]
    ) {
        self.id = id
        self.name = name
        self.relativePath = relativePath
        self.absolutePath = absolutePath
        self.isDirectory = isDirectory
        self.fileKind = fileKind
        self.size = size
        self.modifiedAt = modifiedAt
        self.children = children
    }
}

extension Array where Element == ArtifactNode {
    /// Returns every node in depth-first tree order.
    public func flattenedArtifactNodes() -> [ArtifactNode] {
        var flattened: [ArtifactNode] = []
        flattened.reserveCapacity(count)
        var stack = reversed().map { $0 }
        while let node = stack.popLast() {
            flattened.append(node)
            stack.append(contentsOf: node.children.reversed())
        }
        return flattened
    }
}
