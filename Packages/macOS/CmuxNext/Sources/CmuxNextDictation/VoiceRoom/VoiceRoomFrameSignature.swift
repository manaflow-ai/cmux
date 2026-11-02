public import CoreGraphics

/// A tiny grey thumbnail of a screen frame, to tell whether the screen changed without reading
/// its text: 32 by 20 pixels, one byte each.
public struct VoiceRoomFrameSignature: Equatable, Sendable {
    /// Thumbnail width in pixels.
    public static let width = 32
    /// Thumbnail height in pixels.
    public static let height = 20

    /// The grey pixels, row by row.
    public let pixels: [UInt8]

    /// - Parameter pixels: Exactly `width * height` grey values.
    public init?(pixels: [UInt8]) {
        guard pixels.count == Self.width * Self.height else { return nil }
        self.pixels = pixels
    }

    /// The thumbnail of `image`, nil when it cannot be drawn.
    ///
    /// - Parameter image: A screen frame.
    public init?(image: CGImage) {
        var pixels = [UInt8](repeating: 0, count: Self.width * Self.height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: Self.width, height: Self.height, bitsPerComponent: 8,
                                          bytesPerRow: Self.width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
            return true
        }
        guard drawn else { return nil }
        self.pixels = pixels
    }

    /// How different two frames look, from 0 (same) to 1 (black and white swapped).
    ///
    /// - Parameter other: Another frame's signature.
    /// - Returns: The mean absolute pixel difference over 255.
    public func difference(to other: VoiceRoomFrameSignature) -> Double {
        var total = 0
        for (a, b) in zip(pixels, other.pixels) { total += abs(Int(a) - Int(b)) }
        return Double(total) / Double(pixels.count * 255)
    }
}
