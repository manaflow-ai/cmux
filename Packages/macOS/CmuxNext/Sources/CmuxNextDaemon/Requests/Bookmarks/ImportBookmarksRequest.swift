import Foundation

/// `import-bookmarks`: one transaction. With `sourceKey` and `replace`, the
/// folder carrying `sourceKey` keeps its id and position and takes
/// `nodes[0]`'s title and children.
public struct ImportBookmarksRequest: DaemonRequest {
    public typealias Response = BookmarkImportResult
    public static let command = "import-bookmarks"
    public static let requiredCapability: String? = DaemonCapability.bookmarks.rawValue
    public var browserProfileID: String
    public var parent: String
    public var index: Int?
    public var sourceKey: String?
    public var replace: Bool?
    public var nodes: [BookmarkImportNode]
    public var mutation: MutationIdentity?

    public init(browserProfileID: String, parent: String, index: Int?, sourceKey: String?, replace: Bool?, nodes: [BookmarkImportNode],
                mutation: MutationIdentity?) {
        self.mutation = mutation
        self.browserProfileID = browserProfileID
        self.parent = parent
        self.index = index
        self.sourceKey = sourceKey
        self.replace = replace
        self.nodes = nodes
    }

    enum CodingKeys: String, CodingKey {
        case parent, index, replace, nodes
        case browserProfileID = "browser_profile_id"
        case sourceKey = "source_key"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(browserProfileID, forKey: .browserProfileID)
        try c.encode(parent, forKey: .parent)
        try c.encodeIfPresent(index, forKey: .index)
        try c.encodeIfPresent(sourceKey, forKey: .sourceKey)
        try c.encodeIfPresent(replace, forKey: .replace)
        try c.encode(nodes, forKey: .nodes)
        try MutationFields(identity: mutation).encode(to: encoder)
    }
}

