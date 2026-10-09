public import Foundation

/// One encoded frame from a `BrowserVideoSource`.
public struct BrowserEncodedFrame: Hashable, Sendable {
    /// Annex-B access unit; a keyframe carries its parameter sets.
    public var accessUnit: Data
    public var isKeyframe: Bool
    /// Host monotonic microseconds when the pixels were captured.
    public var captureMicros: UInt64
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(accessUnit: Data, isKeyframe: Bool, captureMicros: UInt64, pixelWidth: Int, pixelHeight: Int) {
        self.accessUnit = accessUnit
        self.isKeyframe = isKeyframe
        self.captureMicros = captureMicros
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}
