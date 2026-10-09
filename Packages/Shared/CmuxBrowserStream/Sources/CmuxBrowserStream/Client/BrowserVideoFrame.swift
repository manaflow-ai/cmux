public import Foundation

/// One reassembled access unit, ready for the decoder.
public struct BrowserVideoFrame: Hashable, Sendable {
    public var frame: UInt32
    /// The frame this one predicts from (`RdFrameBody.refNone` for a keyframe).
    public var refFrame: UInt32
    public var isKeyframe: Bool
    public var codec: BrowserVideoCodec
    /// Host monotonic microseconds when the pixels were captured.
    public var captureMicros: UInt64
    /// Annex-B bytes (parameter sets in front of every keyframe).
    public var accessUnit: Data

    public init(frame: UInt32, refFrame: UInt32, isKeyframe: Bool, codec: BrowserVideoCodec, captureMicros: UInt64,
                accessUnit: Data) {
        self.frame = frame
        self.refFrame = refFrame
        self.isKeyframe = isKeyframe
        self.codec = codec
        self.captureMicros = captureMicros
        self.accessUnit = accessUnit
    }
}
