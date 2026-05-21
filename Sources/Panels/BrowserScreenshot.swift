import AppKit
import UniformTypeIdentifiers
import WebKit

enum BrowserScreenshotError: LocalizedError {
    case emptySnapshot
    case invalidSelection
    case invalidImageRepresentation
    case pasteboardWriteFailed
    case webContentMetricsUnavailable

    var errorDescription: String? {
        switch self {
        case .emptySnapshot:
            return "WebKit did not return a screenshot image."
        case .invalidSelection:
            return "The screenshot selection is empty or outside the browser view."
        case .invalidImageRepresentation:
            return "The screenshot image could not be encoded."
        case .pasteboardWriteFailed:
            return "The screenshot could not be written to the clipboard."
        case .webContentMetricsUnavailable:
            return "The page dimensions could not be read."
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
            x: normalized.minX * scaleX,
            y: normalized.minY * scaleY,
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

private struct BrowserScreenshotWebContentMetrics {
    let contentSize: NSSize
    let viewportSize: NSSize
    let scrollOffset: NSPoint
}

@MainActor
enum BrowserScreenshotWebViewSnapshotter {
    static func captureFullPage(from webView: WKWebView) async throws -> NSImage {
        let metrics = try await webContentMetrics(for: webView)
        do {
            let image = try await captureSingleFullContentSnapshot(from: webView, metrics: metrics)
            if isAcceptableFullContentSnapshot(image, metrics: metrics) {
                return image
            }
        } catch {
            #if DEBUG
            cmuxDebugLog("browser.screenshot.fullPage.singleSnapshot.failed error=\(error.localizedDescription)")
            #endif
        }

        return try await captureStitchedFullPage(from: webView, metrics: metrics)
    }

    static func captureVisibleViewport(from webView: WKWebView) async throws -> NSImage {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        return try await takeSnapshot(from: webView, configuration: configuration)
    }

    private static func captureSingleFullContentSnapshot(
        from webView: WKWebView,
        metrics: BrowserScreenshotWebContentMetrics
    ) async throws -> NSImage {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        configuration.snapshotWidth = nil
        configuration.rect = NSRect(origin: .zero, size: metrics.contentSize)
        return try await takeSnapshot(from: webView, configuration: configuration)
    }

    private static func captureStitchedFullPage(
        from webView: WKWebView,
        metrics: BrowserScreenshotWebContentMetrics
    ) async throws -> NSImage {
        let contentSize = metrics.contentSize
        let viewportSize = metrics.viewportSize
        guard contentSize.width > 0,
              contentSize.height > 0,
              viewportSize.width > 0,
              viewportSize.height > 0 else {
            throw BrowserScreenshotError.webContentMetricsUnavailable
        }

        var tiles: [(origin: NSPoint, image: NSImage)] = []
        let xPositions = tileOrigins(contentLength: contentSize.width, viewportLength: viewportSize.width)
        let yPositions = tileOrigins(contentLength: contentSize.height, viewportLength: viewportSize.height)
        var captureError: Error?

        do {
            for y in yPositions {
                for x in xPositions {
                    try await scroll(webView, to: NSPoint(x: x, y: y))
                    let tile = try await captureVisibleViewport(from: webView)
                    tiles.append((origin: NSPoint(x: x, y: y), image: tile))
                }
            }
        } catch {
            captureError = error
        }

        try? await scroll(webView, to: metrics.scrollOffset)
        if let captureError {
            throw captureError
        }

        guard !tiles.isEmpty else {
            throw BrowserScreenshotError.emptySnapshot
        }

        return stitchedImage(
            tiles: tiles,
            contentSize: contentSize,
            viewportSize: viewportSize
        )
    }

    private static func isAcceptableFullContentSnapshot(
        _ image: NSImage,
        metrics: BrowserScreenshotWebContentMetrics
    ) -> Bool {
        let contentSize = metrics.contentSize
        guard contentSize.width > 0, contentSize.height > 0 else { return false }
        let widthMatches = image.size.width >= contentSize.width * 0.95
        let heightMatches = image.size.height >= contentSize.height * 0.95
        return widthMatches && heightMatches
    }

    private static func tileOrigins(contentLength: CGFloat, viewportLength: CGFloat) -> [CGFloat] {
        guard contentLength > 0, viewportLength > 0 else { return [0] }
        guard contentLength > viewportLength else { return [0] }

        var origins: [CGFloat] = []
        var next: CGFloat = 0
        let last = max(0, contentLength - viewportLength)
        while next < last {
            origins.append(next)
            next += viewportLength
        }
        if origins.last.map({ abs($0 - last) > 0.5 }) ?? true {
            origins.append(last)
        }
        return origins
    }

    private static func stitchedImage(
        tiles: [(origin: NSPoint, image: NSImage)],
        contentSize: NSSize,
        viewportSize: NSSize
    ) -> NSImage {
        let output = NSImage(size: contentSize)
        output.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: contentSize).fill()

        for tile in tiles {
            let drawWidth = min(viewportSize.width, max(0, contentSize.width - tile.origin.x))
            let drawHeight = min(viewportSize.height, max(0, contentSize.height - tile.origin.y))
            guard drawWidth > 0, drawHeight > 0 else { continue }

            let destination = NSRect(
                x: tile.origin.x,
                y: contentSize.height - tile.origin.y - drawHeight,
                width: drawWidth,
                height: drawHeight
            )
            tile.image.draw(
                in: destination,
                from: NSRect(origin: .zero, size: tile.image.size),
                operation: .copy,
                fraction: 1.0
            )
        }

        output.unlockFocus()
        return output
    }

    private static func webContentMetrics(for webView: WKWebView) async throws -> BrowserScreenshotWebContentMetrics {
        let script = """
        (() => {
          const doc = document.documentElement;
          const body = document.body;
          const contentWidth = Math.max(
            doc ? doc.scrollWidth : 0,
            body ? body.scrollWidth : 0,
            doc ? doc.clientWidth : 0,
            window.innerWidth || 0
          );
          const contentHeight = Math.max(
            doc ? doc.scrollHeight : 0,
            body ? body.scrollHeight : 0,
            doc ? doc.clientHeight : 0,
            window.innerHeight || 0
          );
          return {
            contentWidth,
            contentHeight,
            viewportWidth: window.innerWidth || (doc ? doc.clientWidth : 0),
            viewportHeight: window.innerHeight || (doc ? doc.clientHeight : 0),
            scrollX: window.scrollX || 0,
            scrollY: window.scrollY || 0
          };
        })();
        """

        guard let value = try await webView.evaluateJavaScript(script, contentWorld: .page) as? [String: Any] else {
            throw BrowserScreenshotError.webContentMetricsUnavailable
        }

        let contentWidth = numberValue(value["contentWidth"])
        let contentHeight = numberValue(value["contentHeight"])
        let viewportWidth = max(numberValue(value["viewportWidth"]), webView.bounds.width)
        let viewportHeight = max(numberValue(value["viewportHeight"]), webView.bounds.height)
        guard contentWidth > 0, contentHeight > 0, viewportWidth > 0, viewportHeight > 0 else {
            throw BrowserScreenshotError.webContentMetricsUnavailable
        }

        return BrowserScreenshotWebContentMetrics(
            contentSize: NSSize(width: contentWidth, height: contentHeight),
            viewportSize: NSSize(width: viewportWidth, height: viewportHeight),
            scrollOffset: NSPoint(
                x: numberValue(value["scrollX"]),
                y: numberValue(value["scrollY"])
            )
        )
    }

    private static func scroll(_ webView: WKWebView, to point: NSPoint) async throws {
        _ = try await webView.callAsyncJavaScript(
            """
            window.scrollTo(x, y);
            await new Promise((resolve) => {
              requestAnimationFrame(() => requestAnimationFrame(resolve));
            });
            return { x: window.scrollX || 0, y: window.scrollY || 0 };
            """,
            arguments: [
                "x": Double(point.x),
                "y": Double(point.y),
            ],
            in: nil,
            contentWorld: .page
        )
    }

    private static func takeSnapshot(
        from webView: WKWebView,
        configuration: WKSnapshotConfiguration
    ) async throws -> NSImage {
        try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                if let image {
                    continuation.resume(returning: image)
                    return
                }

                continuation.resume(throwing: error ?? BrowserScreenshotError.emptySnapshot)
            }
        }
    }

    private static func numberValue(_ value: Any?) -> CGFloat {
        switch value {
        case let number as NSNumber:
            return CGFloat(number.doubleValue)
        case let double as Double:
            return CGFloat(double)
        case let int as Int:
            return CGFloat(int)
        default:
            return 0
        }
    }
}

extension CmuxWebView {
    func appendScreenshotContextMenuItems(to menu: NSMenu) {
        let pageTitle = String(localized: "browser.contextMenu.screenshotPage", defaultValue: "Screenshot page")
        guard !menu.items.contains(where: {
            $0.action == #selector(contextMenuScreenshotPage(_:)) || $0.title == pageTitle
        }) else {
            return
        }

        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        let pageItem = NSMenuItem(
            title: pageTitle,
            action: #selector(contextMenuScreenshotPage(_:)),
            keyEquivalent: ""
        )
        pageItem.target = self
        menu.addItem(pageItem)
    }

    @objc func contextMenuScreenshotPage(_ sender: Any?) {
        _ = sender
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await BrowserScreenshotPipeline.captureAndWrite(
                    mode: .fullPage,
                    snapshot: { try await BrowserScreenshotWebViewSnapshotter.captureFullPage(from: self) },
                    pasteboard: .general
                )
            } catch {
                #if DEBUG
                cmuxDebugLog("browser.screenshot.page.failed error=\(error.localizedDescription)")
                #endif
                NSSound.beep()
            }
        }
    }
}
