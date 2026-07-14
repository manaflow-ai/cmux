import AppKit
import CMUXMobileCore
import WebKit

extension BrowserPanel {
    /// Marks this browser's current visual state dirty for demanded mobile previews.
    func noteMobileBrowserPreviewContentChanged() {
        MobileBrowserPreviewCoordinator.shared.noteContentChanged(surfaceID: id.uuidString)
    }

    /// Captures and size-bounds one view-only mobile browser preview.
    func mobileBrowserPreviewFrame(
        resolution: MobileBrowserPreviewResolution,
        sequence: UInt64
    ) async -> MobileBrowserPreviewFrame? {
        guard !isClosingWebViewLifecycle else { return nil }
        let bounds = webView.bounds.size
        let sourceWidth = max(1, bounds.width)
        let sourceHeight = max(1, bounds.height)
        let targetLongestEdge: CGFloat = resolution == .full ? 1_200 : 600
        let scale = min(1, targetLongestEdge / max(sourceWidth, sourceHeight))
        let targetWidth = max(1, sourceWidth * scale)
        guard let image = try? await BrowserScreenshotWebViewSnapshotter.captureVisibleViewport(
            from: webView,
            snapshotWidth: targetWidth
        ),
        let encoded = Self.mobileBrowserJPEG(from: image, maximumByteCount: 60 * 1_024) else {
            return nil
        }
        return MobileBrowserPreviewFrame(
            surfaceID: id.uuidString,
            sequence: sequence,
            resolution: resolution,
            title: displayTitle,
            url: currentURL?.absoluteString,
            imageData: encoded.data,
            pixelWidth: encoded.width,
            pixelHeight: encoded.height
        )
    }

    private static func mobileBrowserJPEG(
        from image: NSImage,
        maximumByteCount: Int
    ) -> (data: Data, width: Int, height: Int)? {
        guard let tiff = image.tiffRepresentation,
              var bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        let qualities: [CGFloat] = [0.56, 0.46, 0.36, 0.28, 0.20]
        for _ in 0..<7 {
            for quality in qualities {
                guard let data = bitmap.representation(
                    using: .jpeg,
                    properties: [.compressionFactor: quality]
                ) else { continue }
                if data.count <= maximumByteCount {
                    return (data, bitmap.pixelsWide, bitmap.pixelsHigh)
                }
            }
            guard let resized = mobileBrowserResizedBitmap(bitmap, scale: 0.78) else { break }
            bitmap = resized
        }
        return nil
    }

    private static func mobileBrowserResizedBitmap(
        _ source: NSBitmapImageRep,
        scale: CGFloat
    ) -> NSBitmapImageRep? {
        let width = max(1, Int(CGFloat(source.pixelsWide) * scale))
        let height = max(1, Int(CGFloat(source.pixelsHigh) * scale))
        guard let target = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: target) else { return nil }
        context.imageInterpolation = .high
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        source.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: NSRect(x: 0, y: 0, width: source.pixelsWide, height: source.pixelsHigh),
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        return target
    }
}
