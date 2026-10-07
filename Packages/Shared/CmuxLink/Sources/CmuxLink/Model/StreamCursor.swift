/// A position in one channel direction: the last revision the receiver took,
/// in the session epoch that numbered it. Features may save it and pass it
/// to `openChannel(_:resumeFrom:)`.
public struct StreamCursor: Sendable, Hashable, Codable {
    public var stream: String
    public var epoch: UInt64
    public var revision: UInt64

    public init(stream: String, epoch: UInt64, revision: UInt64) {
        self.stream = stream
        self.epoch = epoch
        self.revision = revision
    }
}
