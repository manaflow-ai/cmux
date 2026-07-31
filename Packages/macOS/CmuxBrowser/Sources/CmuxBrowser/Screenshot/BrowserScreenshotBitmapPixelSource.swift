public import AppKit

/// Adapts an `NSImage` to allocation-free top-left-origin pixel sampling.
public struct BrowserScreenshotBitmapPixelSource: BrowserScreenshotFrameVerifier.PixelSource {
    /// Pixel dimensions of the normalized bitmap representation.
    public let pixelSize: NSSize
    private let bitmap: NSBitmapImageRep
    private let bytesPerPixel: Int
    private let bitmapData: UnsafeMutablePointer<UInt8>

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
        guard let bitmapData = selectedBitmap.bitmapData else {
            return nil
        }
        self.pixelSize = NSSize(
            width: selectedBitmap.pixelsWide,
            height: selectedBitmap.pixelsHigh
        )
        self.bytesPerPixel = samplesPerPixel
        self.bitmapData = bitmapData
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
        context.imageInterpolation = .high
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: outputSize).fill()
        image.draw(
            in: NSRect(origin: .zero, size: outputSize),
            from: NSRect(origin: .zero, size: sourceSize),
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        guard supportsDirectAccess(bitmap) else {
            return nil
        }
        return bitmap
    }

    /// Returns whether a bitmap supports direct packed RGB(A) byte access.
    private static func supportsDirectAccess(_ bitmap: NSBitmapImageRep) -> Bool {
        let unsupportedFormat: NSBitmapImageRep.Format = [
            .alphaFirst,
            .floatingPointSamples,
            .sixteenBitLittleEndian,
            .thirtyTwoBitLittleEndian,
            .sixteenBitBigEndian,
            .thirtyTwoBitBigEndian,
        ]
        let samplesPerPixel = bitmap.samplesPerPixel
        return bitmap.pixelsWide > 0
            && bitmap.pixelsHigh > 0
            && bitmap.bitsPerSample == 8
            && !bitmap.isPlanar
            && bitmap.colorSpace.colorSpaceModel == .rgb
            && (samplesPerPixel == 3 || (samplesPerPixel == 4 && bitmap.hasAlpha))
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
        let alpha = bytesPerPixel == 4
            ? CGFloat(bitmapData[offset + 3]) / 255.0
            : 1.0
        return BrowserScreenshotFrameVerifier.RGBA(
            red: CGFloat(bitmapData[offset]) / 255.0,
            green: CGFloat(bitmapData[offset + 1]) / 255.0,
            blue: CGFloat(bitmapData[offset + 2]) / 255.0,
            alpha: alpha
        )
    }
}
