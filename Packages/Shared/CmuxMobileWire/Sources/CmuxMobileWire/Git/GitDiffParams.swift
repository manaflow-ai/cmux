/// `read git.diff` params. Ask for the list without patches, then one
/// file's patch at a time (`paths: [file]`, `includePatch: true`).
public struct GitDiffParams: Hashable, Sendable, Codable {
    public var path: String
    public var scope: GitDiffScope
    /// Only these files or folders, relative to the repository root.
    public var paths: [String]?
    public var includePatch: Bool?
    public var maxPatchBytes: Int?
    public var maxFiles: Int?

    public init(path: String, scope: GitDiffScope, paths: [String]? = nil, includePatch: Bool? = nil,
                maxPatchBytes: Int? = nil, maxFiles: Int? = nil) {
        self.path = path
        self.scope = scope
        self.paths = paths
        self.includePatch = includePatch
        self.maxPatchBytes = maxPatchBytes
        self.maxFiles = maxFiles
    }

    enum CodingKeys: String, CodingKey {
        case path, scope, paths
        case includePatch = "include_patch"
        case maxPatchBytes = "max_patch_bytes"
        case maxFiles = "max_files"
    }
}
