import AppKit
import Foundation

/// Loads a Stack profile picture and normalizes it into a square bitmap that
/// the AppKit-hosted icon renderer draws as an aspect-fill avatar.
///
/// `AsyncImage` hands its result to SwiftUI as a raster `Image`, which draws
/// nothing on Intel Macs running macOS 15. Decoding here and drawing through
/// `CmuxResolvedIconImage` keeps the real profile picture visible everywhere.
@MainActor
enum StackAccountAvatarImageLoader {
    /// Fetches `url` through the shared URL cache and returns a square avatar
    /// bitmap sized for `pointSize`, or `nil` when the download or decode fails.
    static func load(
        from url: URL,
        pointSize: CGFloat,
        session: URLSession = .shared
    ) async -> NSImage? {
        guard let (data, _) = try? await session.data(from: url) else {
            return nil
        }
        return squareImage(from: data, pointSize: pointSize)
    }

    /// Decodes `data`, center-crops it to a square, and rasterizes it at
    /// `scale` pixels per point so a square image view fills the avatar circle.
    static func squareImage(from data: Data, pointSize: CGFloat, scale: CGFloat = 2) -> NSImage? {
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
