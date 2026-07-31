public import AppKit

/// Adapts an `NSImage` to allocation-free top-left-origin pixel sampling.
public struct BrowserScreenshotBitmapPixelSource: BrowserScreenshotFrameVerifier.PixelSource {
    /// Pixel dimensions of the normalized bitmap representation.
    public let pixelSize: NSSize
    private let bitmap: NSBitmapImageRep
    private let bytesPerPixel: Int
    private let bitmapData: UnsafeMutablePointer<UInt8>
    private let channelOffsets: ChannelOffsets

    private struct ChannelOffsets {
        let red: Int
        let green: Int
        let blue: Int
        let alpha: Int?
    }

    /// Creates a sampler when the image has a supported RGB(A) representation.
    ///
    /// The sampler retains the selected bitmap representation for the lifetime
    /// of the raw byte-plane pointer used by ``color(at:)``.
    ///
    /// - Parameter image: Snapshot image to normalize for direct pixel access.
    /// - Returns: `nil` when the image has no supported 8-bit packed RGB(A) representation.
    public init?(image: NSImage) {
        let candidates = image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .sorted {
                Double($0.pixelsWide) * Double($0.pixelsHigh)
                    > Double($1.pixelsWide) * Double($1.pixelsHigh)
            }
        let selectedBitmap: NSBitmapImageRep
        if let candidate = candidates.first, Self.supportsDirectAccess(candidate) {
            selectedBitmap = candidate
        } else {
            if let normalizedBitmap = Self.normalizedBitmap(from: image) {
                selectedBitmap = normalizedBitmap
            } else if let candidate = candidates.first(where: Self.supportsDirectAccess) {
                selectedBitmap = candidate
            } else {
                return nil
            }
        }
        self.bitmap = selectedBitmap
        let samplesPerPixel = selectedBitmap.samplesPerPixel
        guard let bitmapData = selectedBitmap.bitmapData,
              let channelOffsets = Self.channelOffsets(for: selectedBitmap) else {
            return nil
        }
        self.pixelSize = NSSize(
            width: selectedBitmap.pixelsWide,
            height: selectedBitmap.pixelsHigh
        )
        self.bytesPerPixel = samplesPerPixel
        self.bitmapData = bitmapData
        self.channelOffsets = channelOffsets
    }

    /// Redraws any AppKit/CG image layout into a known packed RGBA bitmap.
    private static func normalizedBitmap(from image: NSImage) -> NSBitmapImageRep? {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        )
        let largestRepresentation = image.representations.max {
            Double($0.pixelsWide) * Double($0.pixelsHigh)
                < Double($1.pixelsWide) * Double($1.pixelsHigh)
        }
        let width = cgImage?.width ?? largestRepresentation?.pixelsWide ?? 0
        let height = cgImage?.height ?? largestRepresentation?.pixelsHigh ?? 0
        guard width > 0,
              height > 0,
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: width,
                  pixelsHigh: height,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }

        let outputSize = NSSize(width: width, height: height)
        let sourceSize = image.size.width > 0 && image.size.height > 0
            ? image.size
            : outputSize
        bitmap.size = outputSize
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.imageInterpolation = .none
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: outputSize).fill()
        image.draw(
            in: NSRect(origin: .zero, size: outputSize),
            from: NSRect(origin: .zero, size: sourceSize),
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.none]
        )
        guard supportsDirectAccess(bitmap) else {
            return nil
        }
        return bitmap
    }

    /// Returns the direct byte offsets for a supported packed RGB(A) bitmap.
    private static func channelOffsets(
        for bitmap: NSBitmapImageRep
    ) -> ChannelOffsets? {
        guard bitmap.samplesPerPixel == 4, bitmap.hasAlpha else {
            if bitmap.samplesPerPixel == 3, !bitmap.hasAlpha {
                return ChannelOffsets(red: 0, green: 1, blue: 2, alpha: nil)
            }
            return nil
        }

        let alphaFirst = bitmap.bitmapFormat.contains(.alphaFirst)
        let littleEndian = bitmap.bitmapFormat.contains(.thirtyTwoBitLittleEndian)
        if littleEndian {
            return alphaFirst
                ? ChannelOffsets(red: 2, green: 1, blue: 0, alpha: 3)
                : ChannelOffsets(red: 3, green: 2, blue: 1, alpha: 0)
        }
        return alphaFirst
            ? ChannelOffsets(red: 1, green: 2, blue: 3, alpha: 0)
            : ChannelOffsets(red: 0, green: 1, blue: 2, alpha: 3)
    }

    /// Returns whether a bitmap supports direct packed RGB(A) byte access.
    private static func supportsDirectAccess(_ bitmap: NSBitmapImageRep) -> Bool {
        let unsupportedFormat: NSBitmapImageRep.Format = [
            .floatingPointSamples,
            .sixteenBitLittleEndian,
            .sixteenBitBigEndian,
        ]
        let samplesPerPixel = bitmap.samplesPerPixel
        return bitmap.pixelsWide > 0
            && bitmap.pixelsHigh > 0
            && bitmap.bitsPerSample == 8
            && !bitmap.isPlanar
            && bitmap.colorSpace.colorSpaceModel == .rgb
            && channelOffsets(for: bitmap) != nil
            && bitmap.bitsPerPixel == samplesPerPixel * 8
            && bitmap.bytesPerRow >= bitmap.pixelsWide * samplesPerPixel
            && bitmap.bitmapFormat.intersection(unsupportedFormat).isEmpty
            && bitmap.bitmapData != nil
    }

    /// Reads one top-left-origin pixel directly from the bitmap byte plane.
    ///
    /// - Parameter point: Pixel coordinate to sample.
    /// - Returns: A normalized color, or `nil` when `point` is outside the bitmap.
    public func color(at point: NSPoint) -> BrowserScreenshotFrameVerifier.RGBA? {
        let x = Int(point.x.rounded(.down))
        let y = Int(point.y.rounded(.down))
        guard x >= 0,
              x < bitmap.pixelsWide,
              y >= 0,
              y < bitmap.pixelsHigh else {
            return nil
        }
        let offset = y * bitmap.bytesPerRow + x * bytesPerPixel
        let alpha = channelOffsets.alpha.map {
            CGFloat(bitmapData[offset + $0]) / 255.0
        } ?? 1.0
        return BrowserScreenshotFrameVerifier.RGBA(
            red: CGFloat(bitmapData[offset + channelOffsets.red]) / 255.0,
            green: CGFloat(bitmapData[offset + channelOffsets.green]) / 255.0,
            blue: CGFloat(bitmapData[offset + channelOffsets.blue]) / 255.0,
            alpha: alpha
        )
    }
}
