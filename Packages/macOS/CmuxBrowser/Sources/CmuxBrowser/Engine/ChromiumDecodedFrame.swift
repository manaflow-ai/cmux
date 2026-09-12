public import CoreGraphics

/// A fully decoded immutable image. CGImage is immutable and safe to hand
/// between executors; only the presentation layer touches AppKit.
public struct ChromiumDecodedFrame: @unchecked Sendable {
    /// The decoded bitmap ready for immediate drawing.
    public let image: CGImage
}
