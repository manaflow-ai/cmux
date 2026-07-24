/// One shared workspace's current layout snapshot.
public struct ShareWorkspaceLayout: Equatable, Sendable {
    /// Wire workspace identifier.
    public var ws: String

    /// Recursive layout root, or `nil` for an empty workspace.
    public var tree: ShareLayoutNode?

    /// Creates a workspace layout snapshot.
    public init(ws: String, tree: ShareLayoutNode?) {
        self.ws = ws
        self.tree = tree
    }
}

extension ShareWorkspaceLayout: Codable {
    private enum CodingKeys: String, CodingKey {
        case ws
        case tree
    }

    /// Decodes a layout snapshot.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ws = try container.decode(String.self, forKey: .ws)
        tree = try container.decodeIfPresent(ShareLayoutNode.self, forKey: .tree)
    }

    /// Encodes a layout snapshot, including an explicit `null` empty tree.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ws, forKey: .ws)
        if let tree {
            try container.encode(tree, forKey: .tree)
        } else {
            try container.encodeNil(forKey: .tree)
        }
    }
}
