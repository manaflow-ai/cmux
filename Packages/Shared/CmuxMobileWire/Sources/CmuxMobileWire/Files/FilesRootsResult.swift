/// `files.roots` result.
public struct FilesRootsResult: Hashable, Sendable, Codable {
    public var roots: [FilesRoot]

    public init(roots: [FilesRoot]) {
        self.roots = roots
    }
}
