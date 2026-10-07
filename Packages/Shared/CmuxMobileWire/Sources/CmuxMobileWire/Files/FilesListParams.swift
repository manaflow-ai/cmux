/// `read files.list` params.
public struct FilesListParams: Hashable, Sendable, Codable {
    public var path: String
    /// Exclusive name to continue after (the previous page's `next`).
    public var after: String?
    public var limit: Int?

    public init(path: String, after: String? = nil, limit: Int? = nil) {
        self.path = path
        self.after = after
        self.limit = limit
    }
}
