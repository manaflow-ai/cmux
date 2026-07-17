/// One immutable directory or file in a GitHub-style changed-file tree.
public struct DiffTreeNode: Identifiable, Sendable, Equatable {
    /// Stable repository-relative identity.
    public var id: String { path }
    /// Display name, including collapsed directory segments when applicable.
    public let name: String
    /// Full repository-relative path.
    public let path: String
    /// Directory or file semantics.
    public let kind: DiffTreeNodeKind
    /// Sorted child nodes for a directory.
    public let children: [DiffTreeNode]

    /// Creates an immutable tree node.
    /// - Parameters:
    ///   - name: Display name for the node.
    ///   - path: Full repository-relative path.
    ///   - kind: Directory or file semantics.
    ///   - children: Sorted directory children.
    public init(name: String, path: String, kind: DiffTreeNodeKind, children: [DiffTreeNode]) {
        self.name = name
        self.path = path
        self.kind = kind
        self.children = children
    }
}
