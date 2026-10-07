/// `channel.open` params of kind `files.upload`.
public struct FilesUploadParams: Hashable, Sendable, Codable {
    public var name: String
    public var size: UInt64
    public var mime: String
    /// Lowercase hex sha256 of the whole file.
    public var sha256: String
    public var dest: FilesUploadDestination

    public init(name: String, size: UInt64, mime: String, sha256: String, dest: FilesUploadDestination) {
        self.name = name
        self.size = size
        self.mime = mime
        self.sha256 = sha256
        self.dest = dest
    }
}
