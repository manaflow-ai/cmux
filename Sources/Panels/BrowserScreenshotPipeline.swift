import AppKit
import UniformTypeIdentifiers

enum BrowserScreenshotError: LocalizedError {
    case captureAreaTooLarge
    case emptySnapshot
    case invalidSelection
    case invalidImageRepresentation
    case pasteboardWriteFailed
    case webContentMetricsUnavailable

    var errorDescription: String? {
        switch self {
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

        let cropped = NSImage(size: cropRect.size)
        cropped.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: cropRect.size),
            from: cropRect,
            operation: .copy,
            fraction: 1.0
        )
        cropped.unlockFocus()
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

enum BrowserScreenshotPasteboardWriter {
    static func write(_ image: NSImage, to pasteboard: NSPasteboard = .general) throws {
        let item = try pasteboardItem(for: image)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw BrowserScreenshotError.pasteboardWriteFailed
        }
    }

    static func pasteboardItem(for image: NSImage) throws -> NSPasteboardItem {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw BrowserScreenshotError.invalidImageRepresentation
        }

        let item = NSPasteboardItem()
        item.setData(pngData, forType: NSPasteboard.PasteboardType(UTType.png.identifier))
        item.setData(tiffData, forType: NSPasteboard.PasteboardType(UTType.tiff.identifier))
        return item
    }
}

enum BrowserScreenshotPipeline {
    typealias SnapshotProvider = @MainActor () async throws -> NSImage

    @MainActor
    static func captureAndWrite(
        mode: BrowserScreenshotCaptureMode,
        snapshot: SnapshotProvider,
        pasteboard: NSPasteboard = .general
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

        try BrowserScreenshotPasteboardWriter.write(output, to: pasteboard)
        return BrowserScreenshotResult(outputSize: output.size)
    }
}
