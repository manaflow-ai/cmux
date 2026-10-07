/// `channel.opened` params of a `files.upload` channel: the upload id and the
/// resume point (bytes the Mac already holds).
public struct FilesUploadOpenedParams: Hashable, Sendable, Codable {
    public var upload: String
    public var offset: UInt64

    public init(upload: String, offset: UInt64) {
        self.upload = upload
        self.offset = offset
    }
}
