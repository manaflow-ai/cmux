/// The identity pair returned by a successful PTY attach: callers must present
/// both to write, resize, or detach the attachment.
public struct RemotePTYBridgeAttachment: Sendable {
    /// Caller-chosen attachment identifier echoed back by the daemon.
    public let attachmentID: String
    /// Daemon-issued secret authorizing operations on this attachment.
    public let token: String
    /// Bytes of initial scrollback replayed before live PTY output.
    public let replayByteCount: Int

    /// Creates an attachment identity; mirrors the original memberwise initializer.
    public init(attachmentID: String, token: String, replayByteCount: Int = 0) {
        self.attachmentID = attachmentID
        self.token = token
        self.replayByteCount = max(0, replayByteCount)
    }
}
