public import CoreGraphics
public import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The part of a picture a Chief wears, as Messages' contact photo editor picks it: a square
/// over the picture (the circle the editor shows sits in it), never past its edges, moved by
/// dragging and made smaller by zooming in.
///
/// Coordinates are the upright picture's pixels with the origin top left (ImageIO's, after its
/// orientation is applied). ``rect`` is the square; ``render(_:)`` makes the saved picture.
///
/// ```swift
/// var crop = HomeChiefPictureCrop(imageSize: CGSize(width: 4000, height: 3000))
/// crop.zoom = 2                                              // a 1500-pixel square, centered
/// crop.pan(by: CGSize(width: 40, height: 0), diameter: 240)  // the picture follows the drag
/// let picture = try crop.render(image)                       // 512 x 512 PNG
/// ```
public nonisolated struct HomeChiefPictureCrop: Hashable, Sendable {
    /// The most the editor zooms in: the square is a fifth of the picture's shorter side.
    public static let maximumZoom: CGFloat = 5
    /// The saved picture's side in pixels (what `pictureData(from:)` keeps for a file).
    public static let outputPixels = 512
    /// The longest side a picture is read at for the editor: more than any crop saves.
    public static let editorPixels = 2048

    /// The upright picture's size in pixels.
    public let imageSize: CGSize
    /// 1 shows the largest square (the picture's shorter side); ``maximumZoom`` the smallest.
    public var zoom: CGFloat { didSet { zoom = min(max(zoom, 1), Self.maximumZoom); clamp() } }
    /// The square's center in picture pixels; kept so the square stays on the picture.
    public private(set) var center: CGPoint

    public init(imageSize: CGSize) {
        self.imageSize = imageSize
        zoom = 1
        center = CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)
    }

    /// The square's side in picture pixels.
    public var side: CGFloat { min(imageSize.width, imageSize.height) / zoom }

    /// The square, in picture pixels (origin top left).
    public var rect: CGRect {
        CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    }

    /// Moves the picture by a drag of `delta` points (AppKit's: y up) in an editor whose circle
    /// is `diameter` points across: the picture follows the pointer, so the square goes the other way.
    public mutating func pan(by delta: CGSize, diameter: CGFloat) {
        guard diameter > 0 else { return }
        let pixelsPerPoint = side / diameter
        center.x -= delta.width * pixelsPerPoint
        center.y += delta.height * pixelsPerPoint
        clamp()
    }

    private mutating func clamp() {
        let half = side / 2
        center.x = min(max(center.x, half), max(imageSize.width - half, half))
        center.y = min(max(center.y, half), max(imageSize.height - half, half))
    }

    /// The square of `image` (the upright picture this crop was made for) as a PNG of
    /// ``outputPixels`` a side, or smaller when the square is smaller.
    /// - Throws: when the picture cannot be drawn or encoded.
    public func render(_ image: CGImage) throws -> ChiefAvatarPicture {
        let scaleX = CGFloat(image.width) / max(imageSize.width, 1)
        let scaleY = CGFloat(image.height) / max(imageSize.height, 1)
        let source = CGRect(x: rect.minX * scaleX, y: rect.minY * scaleY, width: rect.width * scaleX, height: rect.height * scaleY).integral
        guard let square = image.cropping(to: source) else { throw CocoaError(.fileReadCorruptFile) }
        let pixels = min(Self.outputPixels, max(square.width, 1))
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let data = NSMutableData()
        guard let output = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, output, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return ChiefAvatarPicture(mediaType: "image/png", data: data as Data)
    }

    /// The upright picture at `url`, at most ``editorPixels`` on its longer side, for the editor;
    /// nil when ImageIO cannot read it. Reads the file: call it off the main actor.
    public static func editorImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: editorPixels]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Whether the picture at `url` is a GIF, which is kept whole (its frames move), not cropped.
    public static func isAnimated(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = (CGImageSourceGetType(source) as String?).flatMap(UTType.init) else { return false }
        return type.conforms(to: .gif)
    }
}
