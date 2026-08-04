import AppKit
import CMUXMobileCore

@MainActor
struct MobileBrowserFrameEncoder {
    let budget: MobileBrowserFrameSizeBudget

    // nonisolated so the session can use `MobileBrowserFrameEncoder()` as a
    // default argument (default-argument expressions evaluate nonisolated).
    nonisolated init(budget: MobileBrowserFrameSizeBudget = MobileBrowserFrameSizeBudget()) {
        self.budget = budget
    }

    func encode(_ image: NSImage, format: MobileBrowserFrameFormat) throws -> MobileBrowserEncodedFrame {
        var candidate = image
        var jpegQuality = 0.78

        for attempt in 0..<10 {
            guard let bitmap = bitmapRepresentation(for: candidate) else {
                throw MobileBrowserFrameEncodingError.invalidImage
            }
            let data: Data?
            switch format {
            case .jpeg:
                data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
            case .png:
                data = bitmap.representation(using: .png, properties: [:])
            case .unknown:
                data = nil
            }
            guard let data else { throw MobileBrowserFrameEncodingError.invalidImage }
            if budget.contains(encodedByteCount: data.count) {
                return MobileBrowserEncodedFrame(
                    format: format,
                    data: data,
                    pixelWidth: bitmap.pixelsWide,
                    pixelHeight: bitmap.pixelsHigh
                )
            }

            if format == .jpeg, attempt < 2 {
                jpegQuality = max(0.60, jpegQuality - 0.09)
                continue
            }
            let factor = budget.downscaleFactor(encodedByteCount: data.count)
            guard let resized = resizedImage(candidate, factor: factor) else {
                throw MobileBrowserFrameEncodingError.invalidImage
            }
            candidate = resized
            jpegQuality = 0.72
        }
        throw MobileBrowserFrameEncodingError.wireBudgetExceeded
    }

    private func bitmapRepresentation(for image: NSImage) -> NSBitmapImageRep? {
        if let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            return bitmap
        }
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    private func resizedImage(_ image: NSImage, factor: Double) -> NSImage? {
        guard let source = bitmapRepresentation(for: image) else { return nil }
        let width = max(1, Int((Double(source.pixelsWide) * factor).rounded(.down)))
        let height = max(1, Int((Double(source.pixelsHigh) * factor).rounded(.down)))
        guard width < source.pixelsWide || height < source.pixelsHigh,
              let output = NSBitmapImageRep(
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
              let context = NSGraphicsContext(bitmapImageRep: output) else {
            return nil
        }
        output.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        let resized = NSImage(size: output.size)
        resized.addRepresentation(output)
        return resized
    }
}
