public import CoreGraphics
public import Foundation
import CmuxNextCompat
import ImageIO

/// Draws a collage from an explicit snapshot of still pictures the caller has authorized.
///
/// This renderer never resolves paths from record strings or downloads missing art. A future picker
/// integration must authorize each source and supply its local, downloaded image URL before rendering.
public nonisolated struct BackdropCollageRenderer: Sendable {
    private let sources: [String: URL]

    /// Creates a renderer with selection ids mapped to approved, local still-image files.
    public init(sources: [String: URL]) {
        self.sources = sources
    }

    /// Draws every layer at 3200×2000; one unauthorized or unreadable layer refuses the entire drawing.
    ///
    /// Performs synchronous image I/O and CPU work. Call from a repository actor or a background task.
    public func render(_ collage: BackdropCollage) throws -> CGImage {
        try collage.validate()
        for layer in collage.layers where sources[layer.source] == nil {
            throw BackdropCollage.Failure.sourceNotAllowed(layer.source)
        }
        assertBlockingAllowed(.fileIO)
        guard let fill = UInt32(collage.fill.dropFirst(), radix: 16),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 3200, height: 2000, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw BackdropCollage.Failure.renderingFailed
        }
        let channel = { (shift: UInt32) in CGFloat((fill >> shift) & 255) / 255 }
        context.setFillColor(CGColor(srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3200, height: 2000))
        for layer in collage.layers {
            let frame = CGRect(x: layer.x * 3200, y: (1 - layer.y - layer.height) * 2000,
                               width: layer.width * 3200, height: layer.height * 2000)
            guard let url = sources[layer.source], url.isFileURL,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: max(1, Int(ceil(max(frame.width, frame.height) * 1.5))),
                  ] as CFDictionary) else { throw BackdropCollage.Failure.unreadableSource(layer.source) }
            let scale = max(frame.width / CGFloat(picture.width), frame.height / CGFloat(picture.height))
            let drawn = CGRect(x: frame.midX - CGFloat(picture.width) * scale / 2,
                               y: frame.midY - CGFloat(picture.height) * scale / 2,
                               width: CGFloat(picture.width) * scale, height: CGFloat(picture.height) * scale)
            context.saveGState()
            let radius = min(frame.width, frame.height) * layer.cornerRadius
            context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.clip()
            context.setAlpha(layer.opacity)
            context.draw(picture, in: drawn)
            context.restoreGState()
        }
        guard let image = context.makeImage() else { throw BackdropCollage.Failure.renderingFailed }
        return image
    }
}
