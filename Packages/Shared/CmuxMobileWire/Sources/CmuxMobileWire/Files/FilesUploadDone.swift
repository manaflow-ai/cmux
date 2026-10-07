/// `files.upload.done`: the Mac verified and stored the upload at `path`.
public struct FilesUploadDone: Hashable, Sendable {
    public static let name = "files.upload.done"

    public var upload: String
    public var path: String
    public var size: UInt64

    public init(upload: String, path: String, size: UInt64) {
        self.upload = upload
        self.path = path
        self.size = size
    }

    public init?(_ message: ChannelMessage) {
        guard message.name == Self.name,
              let upload = message.body["upload"]?.stringValue,
              let path = message.body["path"]?.stringValue,
              case .int(let size)? = message.body["size"], size >= 0 else { return nil }
        self.init(upload: upload, path: path, size: UInt64(size))
    }

    public var message: ChannelMessage {
        ChannelMessage(name: Self.name, body: ["upload": .string(upload), "path": .string(path), "size": .int(Int64(size))])
    }
}
