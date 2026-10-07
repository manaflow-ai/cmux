/// `channel.opened` params of a `files.download` channel.
public struct FilesDownloadOpenedParams: Hashable, Sendable, Codable {
    public var size: UInt64
    public var mime: String
    public var sha256: String

    public init(size: UInt64, mime: String, sha256: String) {
        self.size = size
        self.mime = mime
        self.sha256 = sha256
    }
}
