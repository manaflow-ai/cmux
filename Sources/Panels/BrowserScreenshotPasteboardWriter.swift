import AppKit
import CmuxBrowser
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
        // `NSBitmapImageRep.cgImage` and AppKit's snapshot reps are both
        // top-row-first, so the encoder must never reorder rows (#18793).
        return try await encode(cgImage)
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated private func encode(
        _ source: CGImage
    ) async throws -> BrowserScreenshotEncodedImage {
        try Task.checkCancellation()
        let bounded = try boundedImage(source)
        try Task.checkCancellation()
        return BrowserScreenshotEncodedImage(
            png: try encodedData(for: bounded, type: UTType.png.identifier),
            tiff: try encodedData(for: bounded, type: UTType.tiff.identifier)
        )
    }

    private nonisolated func boundedImage(_ source: CGImage) throws -> CGImage {
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
        guard width != source.width || height != source.height else {
            return source
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
            source,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        guard let bounded = context.makeImage() else {
            throw BrowserScreenshotError.invalidImageRepresentation
        }
        return bounded
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
