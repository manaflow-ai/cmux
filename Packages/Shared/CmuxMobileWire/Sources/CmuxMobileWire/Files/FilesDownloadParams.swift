/// `channel.open` params of kind `files.download`. `offset` resumes.
public struct FilesDownloadParams: Hashable, Sendable, Codable {
    public var path: String
    public var offset: UInt64?

    public init(path: String, offset: UInt64? = nil) {
        self.path = path
        self.offset = offset
    }
}
