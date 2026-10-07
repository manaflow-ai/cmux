/// A reassembled frame ready to decode.
public struct RdCompletedFrame: Hashable, Sendable {
    public var frame: UInt32
    public var flags: RdFrameFlags
    public var body: RdFrameBody

    public init(frame: UInt32, flags: RdFrameFlags, body: RdFrameBody) {
        self.frame = frame
        self.flags = flags
        self.body = body
    }

    /// Decodable with no earlier frame.
    public var isKeyframe: Bool {
        flags.contains(.keyframe) || body.refFrame == RdFrameBody.refNone
    }
}
