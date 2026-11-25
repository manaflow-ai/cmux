import Foundation

/// A node of `import-bookmarks`: a folder with children or a URL.
public struct BookmarkImportNode: Encodable, Sendable, Equatable {
    public var kind: String
    public var title: String
    public var url: String?
    public var createdMs: Int64?
    public var children: [BookmarkImportNode]?

    public init(kind: String, title: String, url: String?, createdMs: Int64?, children: [BookmarkImportNode]?) {
        self.kind = kind
        self.title = title
        self.url = url
        self.createdMs = createdMs
        self.children = children
    }

    enum CodingKeys: String, CodingKey {
        case kind, title, url, children
        case createdMs = "created_ms"
    }
}

public struct BookmarkImportResult: Decodable, Sendable, Equatable {
    public var rootIDs: [String]
    public var count: Int
    enum CodingKeys: String, CodingKey {
        case count
        case rootIDs = "root_ids"
    }
}
