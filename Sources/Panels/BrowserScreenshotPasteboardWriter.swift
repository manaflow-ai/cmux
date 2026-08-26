import AppKit
import ImageIO
import UniformTypeIdentifiers

struct BrowserScreenshotPasteboardWriter: Sendable {
    static let maximumDesignModeArtifactPixelCount = 4_194_304
    static let maximumOrdinaryClipboardPixelCount = 16_777_216

    private let maximumPixelCount: Int
    private let oversizedImagePolicy: BrowserScreenshotOversizedImagePolicy

    init(
        maximumPixelCount: Int = maximumOrdinaryClipboardPixelCount,
        oversizedImagePolicy: BrowserScreenshotOversizedImagePolicy = .reject
    ) {
        self.maximumPixelCount = maximumPixelCount
        self.oversizedImagePolicy = oversizedImagePolicy
    }

    @MainActor
    func pngData(for image: NSImage) async throws -> Data {
        try await encodedImage(for: image).png
    }

    @MainActor
    func write(_ image: NSImage, to pasteboard: NSPasteboard = .general) async throws {
        let item = try await pasteboardItem(for: image)
        let result = await GhosttyApp.terminalPasteboard
            .replaceContentsAndWait(
                of: pasteboard,
                with: [item]
            )
        guard result.didWrite else {
            throw BrowserScreenshotError.pasteboardWriteFailed
        }
    }

    @MainActor
    func pasteboardItem(for image: NSImage) async throws -> NSPasteboardItem {
        let encoded = try await encodedImage(for: image)
        let item = NSPasteboardItem()
        item.setData(encoded.png, forType: NSPasteboard.PasteboardType(UTType.png.identifier))
        item.setData(encoded.tiff, forType: NSPasteboard.PasteboardType(UTType.tiff.identifier))
        return item
    }

    @MainActor
    private func encodedImage(for image: NSImage) async throws -> BrowserScreenshotEncodedImage {
        let proposedRect = NSRect(origin: .zero, size: image.size)
        let bitmapImage = image.bestRepresentation(
            for: proposedRect,
            context: nil,
            hints: nil
        ) as? NSBitmapImageRep
        guard let cgImage = bitmapImage?.cgImage ?? image.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
        ) else {
            throw BrowserScreenshotError.invalidImageRepresentation
        }
        return try await encode(
            cgImage,
            verticallyFlip: bitmapImage != nil
        )
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated private func encode(
        _ source: CGImage,
        verticallyFlip: Bool
    ) async throws -> BrowserScreenshotEncodedImage {
        try Task.checkCancellation()
        let bounded = try boundedImage(
            source,
            verticallyFlip: verticallyFlip
        )
        try Task.checkCancellation()
        return BrowserScreenshotEncodedImage(
            png: try encodedData(for: bounded, type: UTType.png.identifier),
            tiff: try encodedData(for: bounded, type: UTType.tiff.identifier)
        )
    }

    private nonisolated func boundedImage(
        _ source: CGImage,
        verticallyFlip: Bool
    ) throws -> CGImage {
        guard maximumPixelCount > 0,
              source.width > 0,
              source.height > 0 else {
            throw BrowserScreenshotError.invalidImageRepresentation
        }
        let pixelCount = source.width.multipliedReportingOverflow(by: source.height)
        guard !pixelCount.overflow else {
            throw BrowserScreenshotError.invalidImageRepresentation
        }
        if pixelCount.partialValue > maximumPixelCount,
           oversizedImagePolicy == .reject {
            throw BrowserScreenshotError.captureAreaTooLarge
        }
        let scale = min(
            1,
            sqrt(
                Double(maximumPixelCount)
                    / Double(pixelCount.partialValue)
            )
        )
        var width = max(1, Int((Double(source.width) * scale).rounded(.down)))
        var height = max(1, Int((Double(source.height) * scale).rounded(.down)))
        while width * height > maximumPixelCount {
            if width >= height {
                width -= 1
            } else {
                height -= 1
            }
        }
        let oriented = verticallyFlip
            ? try verticallyFlippedImage(source)
            : source
        guard width != source.width || height != source.height else {
            return oriented
        }
        guard let colorSpace = source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw BrowserScreenshotError.invalidImageRepresentation
        }
        context.interpolationQuality = .high
        context.draw(
            oriented,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        guard let bounded = context.makeImage() else {
            throw BrowserScreenshotError.invalidImageRepresentation
        }
        return bounded
    }

    private nonisolated func verticallyFlippedImage(_ source: CGImage) throws -> CGImage {
        guard let sourceData = source.dataProvider?.data,
              source.bytesPerRow > 0,
              source.height > 0 else {
            throw BrowserScreenshotError.invalidImageRepresentation
        }
        let byteCount = source.bytesPerRow.multipliedReportingOverflow(by: source.height)
        guard !byteCount.overflow,
              CFDataGetLength(sourceData) >= byteCount.partialValue else {
            throw BrowserScreenshotError.invalidImageRepresentation
        }
        var flipped = Data(count: byteCount.partialValue)
        flipped.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress,
                  let sourceBase = CFDataGetBytePtr(sourceData) else { return }
            for row in 0..<source.height {
                memcpy(
                    destinationBase.advanced(by: row * source.bytesPerRow),
                    sourceBase.advanced(by: (source.height - row - 1) * source.bytesPerRow),
                    source.bytesPerRow
                )
            }
        }
        guard let provider = CGDataProvider(data: flipped as CFData),
              let colorSpace = source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: source.width,
                height: source.height,
                bitsPerComponent: source.bitsPerComponent,
                bitsPerPixel: source.bitsPerPixel,
                bytesPerRow: source.bytesPerRow,
                space: colorSpace,
                bitmapInfo: source.bitmapInfo,
                provider: provider,
                decode: source.decode,
                shouldInterpolate: source.shouldInterpolate,
                intent: source.renderingIntent
              ) else {
            throw BrowserScreenshotError.invalidImageRepresentation
        }
        return image
    }

    private nonisolated func encodedData(for image: CGImage, type: String) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            type as CFString,
            1,
            nil
        ) else {
            throw BrowserScreenshotError.invalidImageRepresentation
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw BrowserScreenshotError.invalidImageRepresentation
        }
        return data as Data
    }
}
