/// `read git.status` params: a path inside a root the Mac shares.
public struct GitStatusParams: Hashable, Sendable, Codable {
    public var path: String

    public init(path: String) {
        self.path = path
    }
}
