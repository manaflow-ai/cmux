/// The identity pair returned by a successful PTY attach: callers must present
/// both to write, resize, or detach the attachment.
public struct RemotePTYBridgeAttachment: Sendable {
    /// Caller-chosen attachment identifier echoed back by the daemon.
    public let attachmentID: String
    /// Daemon-issued secret authorizing operations on this attachment.
    public let token: String

    /// Creates an attachment identity; mirrors the original memberwise initializer.
    public init(attachmentID: String, token: String) {
        self.attachmentID = attachmentID
        self.token = token
    }
}
