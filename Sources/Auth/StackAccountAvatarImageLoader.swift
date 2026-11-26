import AppKit
import Foundation

/// Loads a Stack profile picture and normalizes it into a circular bitmap that
/// the AppKit-hosted icon renderer draws as-is.
///
/// `AsyncImage` hands its result to SwiftUI as a raster `Image`, which draws
/// nothing on Intel Macs running macOS 15, and a SwiftUI `clipShape` over the
/// hosted image view goes blank after a while on the same machines. Decoding
/// here, clipping to the circle inside the bitmap, and drawing through
/// `CmuxResolvedIconImage` keeps the real profile picture visible everywhere
/// without SwiftUI owning any pixel of it.
@MainActor
enum StackAccountAvatarImageLoader {
    /// Fetches `url` through the shared URL cache and returns a circular
    /// avatar bitmap sized for `pointSize`, or `nil` when the download or
    /// decode fails.
    static func load(
        from url: URL,
        pointSize: CGFloat,
        session: URLSession = .shared
    ) async -> NSImage? {
        guard let (data, _) = try? await session.data(from: url) else {
            return nil
        }
        return circularImage(from: data, pointSize: pointSize)
    }

    /// Decodes `data`, center-crops it to a square, clips it to the inscribed
    /// circle, and rasterizes it at `scale` pixels per point so the hosted
    /// image view shows the finished avatar without any SwiftUI clipping.
    static func circularImage(from data: Data, pointSize: CGFloat, scale: CGFloat = 2) -> NSImage? {
        guard pointSize.isFinite, pointSize > 0,
              scale.isFinite, scale > 0,
              let source = NSImage(data: data),
              source.size.width > 0,
              source.size.height > 0 else {
            return nil
        }
        let pixels = max(1, Int((pointSize * scale).rounded(.up)))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        let targetSize = NSSize(width: pointSize, height: pointSize)
        bitmap.size = targetSize
        guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }

        let side = min(source.size.width, source.size.height)
        let cropRect = NSRect(
            x: (source.size.width - side) / 2,
            y: (source.size.height - side) / 2,
            width: side,
            height: side
        )

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        graphicsContext.imageInterpolation = .high
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: targetSize).fill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: targetSize)).addClip()
        source.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: cropRect,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: targetSize)
        image.addRepresentation(bitmap)
        image.cacheMode = .never
        return image
    }
}
