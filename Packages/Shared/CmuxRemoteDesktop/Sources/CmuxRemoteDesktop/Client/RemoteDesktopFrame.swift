public import Foundation

/// One reassembled access unit with the view it was encoded for.
public struct RemoteDesktopFrame: Hashable, Sendable {
    public var frame: UInt32
    /// The frame this one predicts from (`RdFrameBody.refNone` for a keyframe).
    public var refFrame: UInt32
    public var isKeyframe: Bool
    /// Host monotonic microseconds when the pixels were captured.
    public var captureMicros: UInt64
    /// Annex-B bytes (parameter sets in front of every keyframe).
    public var accessUnit: Data
    /// The target rect and pixel size this frame shows.
    public var view: DesktopView

    public init(frame: UInt32, refFrame: UInt32, isKeyframe: Bool, captureMicros: UInt64, accessUnit: Data, view: DesktopView) {
        self.frame = frame
        self.refFrame = refFrame
        self.isKeyframe = isKeyframe
        self.captureMicros = captureMicros
        self.accessUnit = accessUnit
        self.view = view
    }
}
