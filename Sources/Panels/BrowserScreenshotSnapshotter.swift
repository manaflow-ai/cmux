import AppKit
import WebKit

private struct BrowserScreenshotWebContentMetrics {
    let contentSize: NSSize
    let viewportSize: NSSize
    let scrollOffset: NSPoint
}

struct BrowserScreenshotTileDrawRects: Equatable {
    let source: NSRect
    let destination: NSRect
}

enum BrowserScreenshotTilePlacement {
    static func drawRects(
        tileSize: NSSize,
        origin: NSPoint,
        contentSize: NSSize,
        viewportSize: NSSize
    ) -> BrowserScreenshotTileDrawRects? {
        let drawWidth = min(viewportSize.width, tileSize.width, max(0, contentSize.width - origin.x))
        let drawHeight = min(viewportSize.height, tileSize.height, max(0, contentSize.height - origin.y))
        guard drawWidth > 0, drawHeight > 0 else { return nil }

        return BrowserScreenshotTileDrawRects(
            source: NSRect(
                x: 0,
                y: max(0, tileSize.height - drawHeight),
                width: drawWidth,
                height: drawHeight
            ),
            destination: NSRect(
                x: origin.x,
                y: contentSize.height - origin.y - drawHeight,
                width: drawWidth,
                height: drawHeight
            )
        )
    }
}

enum BrowserScreenshotCaptureBounds {
    static let maximumFullPagePixels: CGFloat = 100_000_000

    static func validateFullPageSize(_ size: NSSize) throws {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            throw BrowserScreenshotError.webContentMetricsUnavailable
        }

        let pixelCount = ceil(size.width) * ceil(size.height)
        guard pixelCount <= maximumFullPagePixels else {
            throw BrowserScreenshotError.captureAreaTooLarge
        }
    }
}

@MainActor
enum BrowserScreenshotWebViewSnapshotter {
    static func captureFullPage(from webView: WKWebView) async throws -> NSImage {
        let metrics = try await webContentMetrics(for: webView)
        try BrowserScreenshotCaptureBounds.validateFullPageSize(metrics.contentSize)
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
        try BrowserScreenshotCaptureBounds.validateFullPageSize(contentSize)

        let xPositions = tileOrigins(contentLength: contentSize.width, viewportLength: viewportSize.width)
        let yPositions = tileOrigins(contentLength: contentSize.height, viewportLength: viewportSize.height)
        var captureError: Error?
        var didCaptureTile = false
        let output = blankImage(size: contentSize)

        do {
            for y in yPositions {
                for x in xPositions {
                    try await scroll(webView, to: NSPoint(x: x, y: y))
                    let tile = try await captureVisibleViewport(from: webView)
                    drawTile(
                        tile,
                        at: NSPoint(x: x, y: y),
                        into: output,
                        contentSize: contentSize,
                        viewportSize: viewportSize
                    )
                    didCaptureTile = true
                }
            }
        } catch {
            captureError = error
        }

        try? await scroll(webView, to: metrics.scrollOffset)
        if let captureError {
            throw captureError
        }

        guard didCaptureTile else {
            throw BrowserScreenshotError.emptySnapshot
        }

        return output
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

    private static func blankImage(size: NSSize) -> NSImage {
        let output = NSImage(size: size)
        output.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        output.unlockFocus()
        return output
    }

    private static func drawTile(
        _ tile: NSImage,
        at origin: NSPoint,
        into output: NSImage,
        contentSize: NSSize,
        viewportSize: NSSize
    ) {
        guard let rects = BrowserScreenshotTilePlacement.drawRects(
            tileSize: tile.size,
            origin: origin,
            contentSize: contentSize,
            viewportSize: viewportSize
        ) else {
            return
        }

        output.lockFocus()
        defer { output.unlockFocus() }
        tile.draw(
            in: rects.destination,
            from: rects.source,
            operation: .copy,
            fraction: 1.0
        )
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
