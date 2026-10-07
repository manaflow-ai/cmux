/// One directory entry of `files.list`. Symlinks are reported, never followed.
public struct FilesListEntry: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case file
        case dir
        case symlink
    }

    public var name: String
    public var kind: Kind
    public var size: UInt64
    /// Unix milliseconds.
    public var modifiedAt: Int64

    public init(name: String, kind: Kind, size: UInt64, modifiedAt: Int64) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
    }

    enum CodingKeys: String, CodingKey {
        case name, kind, size
        case modifiedAt = "modified_at"
    }
}
