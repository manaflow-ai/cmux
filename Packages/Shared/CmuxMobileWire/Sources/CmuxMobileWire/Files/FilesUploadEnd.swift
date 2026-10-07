/// `files.upload.end`: the phone sent every byte; the Mac verifies `sha256`.
public struct FilesUploadEnd: Hashable, Sendable {
    public static let name = "files.upload.end"

    public var sha256: String

    public init(sha256: String) {
        self.sha256 = sha256
    }

    public init?(_ message: ChannelMessage) {
        guard message.name == Self.name, let sha = message.body["sha256"]?.stringValue else { return nil }
        sha256 = sha
    }

    public var message: ChannelMessage {
        ChannelMessage(name: Self.name, body: ["sha256": .string(sha256)])
    }
}
