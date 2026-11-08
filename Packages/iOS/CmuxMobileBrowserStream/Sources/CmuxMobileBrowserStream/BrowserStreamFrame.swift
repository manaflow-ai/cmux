public import CoreGraphics

/// A decoded browser frame ready for layer-backed display.
// CGImage is immutable; sharing its retained handle across decoder and main actor is safe.
public struct BrowserStreamFrame: @unchecked Sendable {
    /// The subscription-local sequence number.
    public let sequence: UInt64
    /// The decoded image.
    public let image: CGImage
    /// The Mac page viewport size in points.
    public let pageSize: CGSize
    /// The encoded bitmap size in pixels.
    public let pixelSize: CGSize

    /// Creates a decoded browser frame.
    /// - Parameters:
    ///   - sequence: The subscription-local sequence number.
    ///   - image: The decoded Core Graphics image. `CGImage` is immutable and safe to share.
    ///   - pageSize: The Mac page viewport size in points.
    ///   - pixelSize: The encoded bitmap size in pixels.
    public init(sequence: UInt64, image: CGImage, pageSize: CGSize, pixelSize: CGSize) {
        self.sequence = sequence
        self.image = image
        self.pageSize = pageSize
        self.pixelSize = pixelSize
    }
}
