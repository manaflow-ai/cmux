import AppKit
import ImageIO
import UniformTypeIdentifiers

enum BrowserScreenshotError: LocalizedError {
    case automationTimedOut
    case captureAreaTooLarge
    case emptySnapshot
    case invalidSelection
    case invalidImageRepresentation
    case pasteboardWriteFailed
    case webContentMetricsUnavailable

    var errorDescription: String? {
        switch self {
        case .automationTimedOut:
            return String(
                localized: "browser.screenshot.error.automationTimedOut",
                defaultValue: "Timed out waiting for the browser screenshot."
            )
        case .captureAreaTooLarge:
            return String(
                localized: "browser.screenshot.error.captureAreaTooLarge",
                defaultValue: "The page is too large to capture."
            )
        case .emptySnapshot:
            return String(localized: "browser.screenshot.error.emptySnapshot", defaultValue: "No screenshot was returned.")
        case .invalidSelection:
            return String(
                localized: "browser.screenshot.error.invalidSelection",
                defaultValue: "The screenshot selection is empty or outside the browser view."
            )
        case .invalidImageRepresentation:
            return String(
                localized: "browser.screenshot.error.invalidImageRepresentation",
                defaultValue: "The screenshot image could not be encoded."
            )
        case .pasteboardWriteFailed:
            return String(
                localized: "browser.screenshot.error.pasteboardWriteFailed",
                defaultValue: "The screenshot could not be written to the clipboard."
            )
        case .webContentMetricsUnavailable:
            return String(
                localized: "browser.screenshot.error.webContentMetricsUnavailable",
                defaultValue: "The page dimensions could not be read."
            )
        }
    }
}

enum BrowserScreenshotCaptureMode {
    case fullPage
    case section(selectionInView: NSRect, viewBounds: NSRect)
}

struct BrowserScreenshotResult {
    let outputSize: NSSize
}

@MainActor
final class BrowserScreenshotCaptureGate {
    private var isRunning = false

    func begin() -> Bool {
        guard !isRunning else {
            return false
        }

        isRunning = true
        return true
    }

    func end() {
        isRunning = false
    }

    func run<T>(_ operation: @MainActor () async throws -> T) async throws -> T? {
        guard begin() else {
            return nil
        }

        defer {
            end()
        }
        return try await operation()
    }
}

enum BrowserScreenshotCrop {
    static func imageRect(
        forSelectionInView selection: NSRect,
        viewBounds: NSRect,
        imageSize: NSSize
    ) throws -> NSRect {
        let normalized = normalizedSelection(selection, in: viewBounds)
        guard normalized.width > 0,
              normalized.height > 0,
              viewBounds.width > 0,
              viewBounds.height > 0,
              imageSize.width > 0,
              imageSize.height > 0 else {
            throw BrowserScreenshotError.invalidSelection
        }

        let scaleX = imageSize.width / viewBounds.width
        let scaleY = imageSize.height / viewBounds.height
        let imageRect = NSRect(
            x: (normalized.minX - viewBounds.minX) * scaleX,
            y: (normalized.minY - viewBounds.minY) * scaleY,
            width: normalized.width * scaleX,
            height: normalized.height * scaleY
        )
        return clamp(imageRect, to: NSRect(origin: .zero, size: imageSize))
    }

    @MainActor
    static func croppedImage(
        from image: NSImage,
        selectionInView selection: NSRect,
        viewBounds: NSRect
    ) throws -> NSImage {
        let cropRect = try imageRect(
            forSelectionInView: selection,
            viewBounds: viewBounds,
            imageSize: image.size
        ).integral
        guard cropRect.width > 0, cropRect.height > 0 else {
            throw BrowserScreenshotError.invalidSelection
        }

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(cropRect.width),
            pixelsHigh: Int(cropRect.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw BrowserScreenshotError.invalidImageRepresentation
        }

        bitmap.size = cropRect.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: cropRect.size),
            from: cropRect,
            operation: .copy,
            fraction: 1.0,
            respectFlipped: false,
            hints: nil
        )
        NSGraphicsContext.restoreGraphicsState()

        let cropped = NSImage(size: cropRect.size)
        cropped.addRepresentation(bitmap)
        return cropped
    }

    private static func normalizedSelection(_ selection: NSRect, in bounds: NSRect) -> NSRect {
        let minX = min(selection.minX, selection.maxX)
        let minY = min(selection.minY, selection.maxY)
        let rect = NSRect(
            x: minX,
            y: minY,
            width: abs(selection.width),
            height: abs(selection.height)
        )
        return clamp(rect, to: bounds)
    }

    private static func clamp(_ rect: NSRect, to bounds: NSRect) -> NSRect {
        let minX = max(bounds.minX, min(rect.minX, bounds.maxX))
        let maxX = max(bounds.minX, min(rect.maxX, bounds.maxX))
        let minY = max(bounds.minY, min(rect.minY, bounds.maxY))
        let maxY = max(bounds.minY, min(rect.maxY, bounds.maxY))
        return NSRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }
}

struct BrowserScreenshotPasteboardWriter: Sendable {
    static let defaultMaximumPixelCount = 4_194_304

    private struct EncodedImage: Sendable {
        let png: Data
        let tiff: Data
    }

    private let maximumPixelCount: Int

    init(maximumPixelCount: Int = defaultMaximumPixelCount) {
        self.maximumPixelCount = maximumPixelCount
    }

    @MainActor
    func pngData(for image: NSImage) async throws -> Data {
        try await encodedImage(for: image).png
    }

    @MainActor
    func write(_ image: NSImage, to pasteboard: NSPasteboard = .general) async throws {
        let item = try await pasteboardItem(for: image)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
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
    private func encodedImage(for image: NSImage) async throws -> EncodedImage {
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
    ) async throws -> EncodedImage {
        try Task.checkCancellation()
        let bounded = try boundedImage(
            source,
            verticallyFlip: verticallyFlip
        )
        try Task.checkCancellation()
        return EncodedImage(
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

enum BrowserScreenshotPipeline {
    typealias SnapshotProvider = @MainActor () async throws -> NSImage

    @MainActor
    static func captureAndWrite(
        mode: BrowserScreenshotCaptureMode,
        snapshot: SnapshotProvider,
        pasteboard: NSPasteboard = .general,
        pasteboardWriter: BrowserScreenshotPasteboardWriter = .init()
    ) async throws -> BrowserScreenshotResult {
        let captured = try await snapshot()
        let output: NSImage
        switch mode {
        case .fullPage:
            output = captured
        case let .section(selectionInView, viewBounds):
            output = try BrowserScreenshotCrop.croppedImage(
                from: captured,
                selectionInView: selectionInView,
                viewBounds: viewBounds
            )
        }

        try await pasteboardWriter.write(output, to: pasteboard)
        return BrowserScreenshotResult(outputSize: output.size)
    }
}
