/// Where an upload lands (`files.upload` params `dest`). `terminal` and
/// `composer` land in the Mac's inbox; `path` names a directory under a
/// writable root.
public struct FilesUploadDestination: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case terminal
        case composer
        case path
    }

    public var kind: Kind
    public var terminal: String?
    public var path: String?

    public init(kind: Kind, terminal: String? = nil, path: String? = nil) {
        self.kind = kind
        self.terminal = terminal
        self.path = path
    }
}
