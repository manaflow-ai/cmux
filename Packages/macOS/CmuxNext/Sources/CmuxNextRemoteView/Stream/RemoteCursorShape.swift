public import CoreGraphics
public import Foundation

/// One remote cursor shape in stream pixels (`cursor_shape`): the image as large
/// as the remote screen shows it in the stream, and its hotspot from the top left.
/// Equal by id (the host's hash of size, hotspot and pixels).
public nonisolated final class RemoteCursorShape: Sendable, Hashable {
    public let id: UInt32
    public let image: CGImage
    public let pixelSize: CGSize
    public let hotSpot: CGPoint

    public init(id: UInt32, image: CGImage, hotSpot: CGPoint) {
        self.id = id
        self.image = image
        pixelSize = CGSize(width: image.width, height: image.height)
        self.hotSpot = hotSpot
    }

    /// The shape from a `cursor_shape` message: premultiplied RGBA8, rows top first.
    /// Nil when the pixels do not match the size (or the size is out of range).
    public convenience init?(id: UInt32, width: Int, height: Int, hotX: Int, hotY: Int, rgba: Data) {
        guard (1...Self.maxSide).contains(width), (1...Self.maxSide).contains(height),
              rgba.count == width * height * 4,
              let provider = CGDataProvider(data: rgba as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        self.init(id: id, image: image,
                  hotSpot: CGPoint(x: min(max(hotX, 0), width - 1), y: min(max(hotY, 0), height - 1)))
    }

    /// cmux-rd-proto `MAX_CURSOR_SIDE`.
    public static let maxSide = 256

    public static func == (lhs: RemoteCursorShape, rhs: RemoteCursorShape) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
