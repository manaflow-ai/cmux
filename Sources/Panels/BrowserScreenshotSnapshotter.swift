import AppKit
import CmuxBrowser
import CmuxFoundation
import WebKit

enum BrowserScreenshotCaptureBounds {
    static let maximumFullPagePixels: CGFloat = 100_000_000
    static let maximumSelectionPixels: CGFloat = 4_194_304

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

    static func boundedSnapshotWidth(for rect: NSRect) throws -> CGFloat {
        guard rect.minX.isFinite,
              rect.minY.isFinite,
              rect.maxX.isFinite,
              rect.maxY.isFinite,
              rect.width.isFinite,
              rect.height.isFinite,
              rect.width > 0,
              rect.height > 0 else {
            throw BrowserScreenshotError.invalidSelection
        }
        let areaBoundedWidth = sqrt(
            maximumSelectionPixels * rect.width / rect.height
        )
        let width = floor(min(rect.width, areaBoundedWidth))
        guard width >= 1 else {
            throw BrowserScreenshotError.captureAreaTooLarge
        }
        return width
    }

    static func boundedOutputSize(
        for size: NSSize,
        maximumPixelCount: Int
    ) throws -> NSSize {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0,
              maximumPixelCount > 0 else {
            throw BrowserScreenshotError.invalidImageRepresentation
        }
        let sourceWidth = ceil(size.width)
        let sourceHeight = ceil(size.height)
        let sourcePixelCount = sourceWidth * sourceHeight
        guard sourcePixelCount.isFinite, sourcePixelCount > 0 else {
            throw BrowserScreenshotError.invalidImageRepresentation
        }
        let scale = min(
            1,
            sqrt(CGFloat(maximumPixelCount) / sourcePixelCount)
        )
        var width = max(1, Int(floor(sourceWidth * scale)))
        var height = max(1, Int(floor(sourceHeight * scale)))
        let candidatePixelCount = width.multipliedReportingOverflow(by: height)
        if candidatePixelCount.overflow || candidatePixelCount.partialValue > maximumPixelCount {
            if width >= height {
                width = max(1, min(width, maximumPixelCount / height))
            } else {
                height = max(1, min(height, maximumPixelCount / width))
            }
        }
        let boundedPixelCount = width.multipliedReportingOverflow(by: height)
        guard !boundedPixelCount.overflow,
              boundedPixelCount.partialValue <= maximumPixelCount else {
            throw BrowserScreenshotError.invalidImageRepresentation
        }
        return NSSize(width: width, height: height)
    }
}

@MainActor
enum BrowserScreenshotWebViewSnapshotter {
    static func captureFullPage(
        from webView: WKWebView,
        afterScreenUpdates: Bool = true,
        onProgress: @escaping @MainActor () -> Void = {}
    ) async throws -> NSImage {
        try Task.checkCancellation()
        let metrics = try await webContentMetrics(for: webView)
        onProgress()
        try Task.checkCancellation()
        try BrowserScreenshotCaptureBounds.validateFullPageSize(metrics.contentSize)
        if let snapshotRect = metrics.untransformedFullContentSnapshotRect(in: webView.bounds) {
            do {
                let image = try await captureSingleFullContentSnapshot(
                    from: webView,
                    snapshotRect: snapshotRect,
                    afterScreenUpdates: afterScreenUpdates
                )
                onProgress()
                try Task.checkCancellation()
                if isAcceptableFullContentSnapshot(image, metrics: metrics) {
                    return image
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                onProgress()
                #if DEBUG
                cmuxDebugLog("browser.screenshot.fullPage.singleSnapshot.failed error=\(error.localizedDescription)")
                #endif
            }
        }

        return try await captureStitchedFullPage(
            from: webView,
            metrics: metrics,
            afterScreenUpdates: afterScreenUpdates,
            onProgress: onProgress
        )
    }

    /// Captures a Design Mode overview at its final bounded resolution so
    /// WebKit and AppKit never materialize the full document-sized bitmap.
    static func captureBoundedFullPageOverview(
        from webView: WKWebView,
        maximumPixelCount: Int,
        afterScreenUpdates: Bool = true,
        onProgress: @escaping @MainActor () -> Void = {}
    ) async throws -> NSImage {
        try Task.checkCancellation()
        let metrics = try await webContentMetrics(for: webView)
        onProgress()
        try Task.checkCancellation()
        try BrowserScreenshotCaptureBounds.validateFullPageSize(metrics.contentSize)
        let outputSize = try BrowserScreenshotCaptureBounds.boundedOutputSize(
            for: metrics.contentSize,
            maximumPixelCount: maximumPixelCount
        )
        guard let renderer = viewportSnapshotRenderer(
            outputPixelSize: outputSize,
            for: webView
        ) else {
            throw BrowserScreenshotError.captureAreaTooLarge
        }
        if let snapshotRect = metrics.untransformedFullContentSnapshotRect(in: webView.bounds) {
            do {
                let image = try await captureSingleFullContentSnapshot(
                    from: webView,
                    snapshotRect: snapshotRect,
                    afterScreenUpdates: afterScreenUpdates,
                    renderer: renderer
                )
                onProgress()
                try Task.checkCancellation()
                guard isAcceptableFullContentSnapshot(image, expectedSize: outputSize) else {
                    throw BrowserScreenshotError.emptySnapshot
                }
                return image
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                onProgress()
                #if DEBUG
                cmuxDebugLog("browser.screenshot.designMode.singleSnapshot.failed error=\(error.localizedDescription)")
                #endif
            }
        }

        return try await captureBoundedDocumentRegion(
            from: webView,
            region: NSRect(origin: .zero, size: metrics.contentSize),
            metrics: metrics,
            maximumPixelCount: maximumPixelCount,
            afterScreenUpdates: afterScreenUpdates,
            onProgress: onProgress
        )
    }

    static func captureVisibleViewport(
        from webView: WKWebView,
        afterScreenUpdates: Bool = true,
        timeout: TimeInterval? = nil
    ) async throws -> NSImage {
        let renderer = viewportSnapshotRenderer(for: webView)
        return try await captureVisibleViewport(
            from: webView,
            afterScreenUpdates: afterScreenUpdates,
            renderer: renderer,
            timeout: timeout
        )
    }

    static func captureDocumentRect(
        _ rect: NSRect,
        from webView: WKWebView,
        afterScreenUpdates: Bool = true,
        onProgress: @escaping @MainActor () -> Void = {}
    ) async throws -> NSImage {
        try Task.checkCancellation()
        let metrics = try await webContentMetrics(for: webView)
        onProgress()
        let bounds = webView.bounds
        let scaleX = bounds.width / metrics.viewportSize.width
        let scaleY = bounds.height / metrics.viewportSize.height
        guard scaleX.isFinite,
              scaleY.isFinite,
              scaleX > 0,
              scaleY > 0 else {
            throw BrowserScreenshotError.webContentMetricsUnavailable
        }
        let documentRect = NSRect(
            x: (rect.minX - bounds.minX) / scaleX,
            y: (rect.minY - bounds.minY) / scaleY,
            width: rect.width / scaleX,
            height: rect.height / scaleY
        )
        return try await captureBoundedDocumentRegion(
            from: webView,
            region: documentRect,
            metrics: metrics,
            maximumPixelCount: Int(BrowserScreenshotCaptureBounds.maximumSelectionPixels),
            afterScreenUpdates: afterScreenUpdates,
            onProgress: onProgress
        )
    }

    static func captureVisibleViewport(
        from webView: WKWebView,
        afterScreenUpdates: Bool = true,
        completion: @escaping @MainActor (Result<NSImage, Error>) -> Void
    ) {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = afterScreenUpdates
        let renderer = viewportSnapshotRenderer(for: webView)
        configuration.snapshotWidth = renderer?.snapshotWidth
        takeSnapshot(
            from: webView,
            configuration: configuration,
            renderer: renderer,
            completion: completion
        )
    }

    private static func captureSingleFullContentSnapshot(
        from webView: WKWebView,
        snapshotRect: NSRect,
        afterScreenUpdates: Bool,
        renderer: BrowserViewportSnapshotRenderer? = nil
    ) async throws -> NSImage {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = afterScreenUpdates
        configuration.snapshotWidth = renderer?.snapshotWidth
        configuration.rect = snapshotRect
        let image = try await takeSnapshot(from: webView, configuration: configuration)
        guard let renderer else { return image }
        guard hasExpectedPixelCoverage(
            image,
            expectedSize: renderer.plan.outputPixelSize
        ) else {
            throw BrowserScreenshotError.emptySnapshot
        }
        guard let normalized = renderer.normalizedImage(image) else {
            throw BrowserScreenshotError.invalidImageRepresentation
        }
        return normalized
    }

    private static func captureStitchedFullPage(
        from webView: WKWebView,
        metrics: BrowserViewportContentMetrics,
        afterScreenUpdates: Bool,
        onProgress: @escaping @MainActor () -> Void
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

        guard let tilePlan = BrowserFullPageTilePlan(
            contentSize: contentSize,
            viewportSize: viewportSize
        ) else {
            throw BrowserScreenshotError.captureAreaTooLarge
        }
        guard let tileRenderer = viewportSnapshotRenderer(
            outputPixelSize: viewportSize,
            for: webView
        ) else {
            throw BrowserScreenshotError.captureAreaTooLarge
        }
        var captureError: Error?
        var didCaptureTile = false
        let output = blankImage(size: contentSize)

        do {
            for row in 0..<tilePlan.rowCount {
                for column in 0..<tilePlan.columnCount {
                    try Task.checkCancellation()
                    guard let origin = tilePlan.origin(column: column, row: row) else {
                        throw BrowserScreenshotError.webContentMetricsUnavailable
                    }
                    let actualOrigin = try await scroll(webView, to: origin)
                    onProgress()
                    try Task.checkCancellation()
                    let tile = try await captureVisibleViewport(
                        from: webView,
                        afterScreenUpdates: afterScreenUpdates,
                        renderer: tileRenderer
                    )
                    onProgress()
                    try Task.checkCancellation()
                    drawTile(
                        tile,
                        at: actualOrigin,
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

        // Restore the page in a fresh task because a cancelled capture task
        // must not leave the user's page scrolled to an intermediate tile.
        let restoration = Task { @MainActor [weak webView] in
            guard let webView else { return }
            _ = try? await scroll(webView, to: metrics.scrollOffset)
        }
        await restoration.value
        onProgress()
        if let captureError {
            throw captureError
        }
        try Task.checkCancellation()

        guard didCaptureTile else {
            throw BrowserScreenshotError.emptySnapshot
        }

        return output
    }

    /// Captures a CSS document region into an exact bounded bitmap. Tiles are
    /// normalized in CSS pixels before being mapped into the smaller output,
    /// so zoomed/emulated viewports and large selections use the same path.
    private static func captureBoundedDocumentRegion(
        from webView: WKWebView,
        region: NSRect,
        metrics: BrowserViewportContentMetrics,
        maximumPixelCount: Int,
        afterScreenUpdates: Bool,
        onProgress: @escaping @MainActor () -> Void
    ) async throws -> NSImage {
        let pageRect = NSRect(origin: .zero, size: metrics.contentSize)
        let captureRegion = region.standardized.intersection(pageRect)
        guard !captureRegion.isNull,
              captureRegion.width > 0,
              captureRegion.height > 0,
              let tilePlan = BrowserFullPageTilePlan(
                  contentSize: captureRegion.size,
                  viewportSize: metrics.viewportSize
              ),
              let tileRenderer = viewportSnapshotRenderer(
                  outputPixelSize: metrics.viewportSize,
                  for: webView
              ) else {
            throw BrowserScreenshotError.captureAreaTooLarge
        }
        let outputSize = try BrowserScreenshotCaptureBounds.boundedOutputSize(
            for: captureRegion.size,
            maximumPixelCount: maximumPixelCount
        )
        let bitmap = try blankBitmapRepresentation(size: outputSize)
        var captureError: (any Error)?
        var didDrawTile = false

        do {
            for row in 0..<tilePlan.rowCount {
                for column in 0..<tilePlan.columnCount {
                    try Task.checkCancellation()
                    guard let relativeOrigin = tilePlan.origin(column: column, row: row) else {
                        throw BrowserScreenshotError.webContentMetricsUnavailable
                    }
                    let actualOrigin = try await scroll(
                        webView,
                        to: NSPoint(
                            x: captureRegion.minX + relativeOrigin.x,
                            y: captureRegion.minY + relativeOrigin.y
                        )
                    )
                    onProgress()
                    try Task.checkCancellation()
                    let tile = try await captureVisibleViewport(
                        from: webView,
                        afterScreenUpdates: afterScreenUpdates,
                        renderer: tileRenderer
                    )
                    onProgress()
                    try Task.checkCancellation()
                    didDrawTile = drawBoundedRegionTile(
                        tile,
                        visibleOrigin: actualOrigin,
                        viewportSize: metrics.viewportSize,
                        captureRegion: captureRegion,
                        outputSize: outputSize,
                        into: bitmap
                    ) || didDrawTile
                }
            }
        } catch {
            captureError = error
        }

        // Restoration is independent of caller cancellation so Design Mode
        // never leaves the page at an intermediate stitched-capture offset.
        let restoration = Task { @MainActor [weak webView] in
            guard let webView else { return }
            _ = try? await scroll(webView, to: metrics.scrollOffset)
        }
        await restoration.value
        onProgress()
        if let captureError {
            throw captureError
        }
        try Task.checkCancellation()
        guard didDrawTile else {
            throw BrowserScreenshotError.emptySnapshot
        }

        let output = NSImage(size: outputSize)
        output.addRepresentation(bitmap)
        return output
    }

    private static func blankBitmapRepresentation(size: NSSize) throws -> NSBitmapImageRep {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
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
            throw BrowserScreenshotError.invalidImageRepresentation
        }
        bitmap.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    private static func drawBoundedRegionTile(
        _ tile: NSImage,
        visibleOrigin: NSPoint,
        viewportSize: NSSize,
        captureRegion: NSRect,
        outputSize: NSSize,
        into bitmap: NSBitmapImageRep
    ) -> Bool {
        guard tile.size.width > 0,
              tile.size.height > 0,
              viewportSize.width > 0,
              viewportSize.height > 0,
              captureRegion.width > 0,
              captureRegion.height > 0,
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return false
        }
        let visibleRect = NSRect(origin: visibleOrigin, size: viewportSize)
        let intersection = visibleRect.intersection(captureRegion)
        guard !intersection.isNull,
              intersection.width > 0,
              intersection.height > 0 else {
            return false
        }
        let tileScaleX = tile.size.width / viewportSize.width
        let tileScaleY = tile.size.height / viewportSize.height
        let outputScaleX = outputSize.width / captureRegion.width
        let outputScaleY = outputSize.height / captureRegion.height
        let source = NSRect(
            x: (intersection.minX - visibleOrigin.x) * tileScaleX,
            y: tile.size.height - (intersection.maxY - visibleOrigin.y) * tileScaleY,
            width: intersection.width * tileScaleX,
            height: intersection.height * tileScaleY
        )
        let destination = NSRect(
            x: (intersection.minX - captureRegion.minX) * outputScaleX,
            y: outputSize.height - (intersection.maxY - captureRegion.minY) * outputScaleY,
            width: intersection.width * outputScaleX,
            height: intersection.height * outputScaleY
        )

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        tile.draw(
            in: destination,
            from: source,
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.restoreGraphicsState()
        return true
    }

    static func withOffscreenRenderHost<T>(
        _ webView: WKWebView,
        viewportSize: NSSize,
        expectedURL: URL?,
        timingBudget: BrowserScreenshotTimingBudget = .init(),
        operation: () async throws -> T
    ) async throws -> T {
        let renderHost = BrowserOffscreenRenderHost(
            webView: webView,
            viewportSize: viewportSize
        )
        defer { renderHost.restore() }

        try await prepareForVisualCapture(
            webView,
            expectedURL: expectedURL,
            timingBudget: timingBudget
        )
        return try await operation()
    }

    static func withOffscreenRenderHost<T>(
        _ webView: WKWebView,
        viewportSize: NSSize,
        expectedURL: URL?,
        timeout: TimeInterval,
        timingBudget: BrowserScreenshotTimingBudget = .init(),
        operation: @escaping @MainActor () async throws -> T,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        let renderHost = BrowserOffscreenRenderHost(
            webView: webView,
            viewportSize: viewportSize
        )

        var timeoutTimer: Timer?
        let lease = BrowserScreenshotRenderLease<T>(
            teardown: {
                renderHost.restore()
            },
            completion: completion
        )
        let finish: @MainActor (Result<T, Error>) -> Void = { result in
            guard lease.finish(result) else { return }
            timeoutTimer?.invalidate()
            timeoutTimer = nil
        }

        let timer = Timer(timeInterval: timeout, repeats: false) { _ in
            MainActor.assumeIsolated {
                finish(.failure(BrowserScreenshotError.automationTimedOut))
            }
        }
        timeoutTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        let operationTask = Task { @MainActor in
            do {
                try await prepareForVisualCapture(
                    webView,
                    expectedURL: expectedURL,
                    timingBudget: timingBudget
                )
                try Task.checkCancellation()
                finish(.success(try await operation()))
            } catch {
                finish(.failure(error))
            }
        }
        lease.installOperationTask(operationTask)
    }

    static func prepareForVisualCapture(
        _ webView: WKWebView,
        expectedURL: URL?,
        timingBudget: BrowserScreenshotTimingBudget = .init()
    ) async throws {
        try await waitForExpectedURLIfNeeded(
            webView,
            expectedURL: expectedURL,
            timeout: timingBudget.expectedURLAllowance
        )

        forceAppKitLayout(for: webView)

        do {
            _ = try await BrowserScreenshotJavaScriptRequest(
                webView: webView,
                timeout: timingBudget.preparationJavaScriptAllowance
            ).evaluate(script: visualCaptureLayoutFlushScript)
        } catch {
            #if DEBUG
            cmuxDebugLog("browser.screenshot.prepare.failed error=\(error.localizedDescription)")
            #endif
        }

        forceAppKitLayout(for: webView)
    }

    private static func isAcceptableFullContentSnapshot(
        _ image: NSImage,
        metrics: BrowserViewportContentMetrics
    ) -> Bool {
        isAcceptableFullContentSnapshot(image, expectedSize: metrics.contentSize)
    }

    private static func isAcceptableFullContentSnapshot(
        _ image: NSImage,
        expectedSize: NSSize
    ) -> Bool {
        guard expectedSize.width > 0, expectedSize.height > 0 else { return false }
        let widthMatches = image.size.width >= expectedSize.width * 0.95
        let heightMatches = image.size.height >= expectedSize.height * 0.95
        return widthMatches && heightMatches
    }

    /// Checks WebKit's unmodified bitmap before normalization can stretch a
    /// clipped viewport result into the requested full-document dimensions.
    private static func hasExpectedPixelCoverage(
        _ image: NSImage,
        expectedSize: NSSize
    ) -> Bool {
        guard expectedSize.width > 0, expectedSize.height > 0 else { return false }
        return image.representations.contains { representation in
            CGFloat(representation.pixelsWide) >= expectedSize.width * 0.95
                && CGFloat(representation.pixelsHigh) >= expectedSize.height * 0.95
        }
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

    private static func webContentMetrics(for webView: WKWebView) async throws -> BrowserViewportContentMetrics {
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
        let containerBounds = webView.cmuxBrowserViewportContainerBounds
            ?? CGRect(origin: .zero, size: webView.bounds.size)
        let fallbackViewportSize = webView.cmuxBrowserViewportLayout(in: containerBounds)?.bounds.size
            ?? webView.bounds.size
        guard let metrics = BrowserViewportContentMetrics(
            contentSize: CGSize(width: contentWidth, height: contentHeight),
            reportedViewportSize: CGSize(
                width: numberValue(value["viewportWidth"]),
                height: numberValue(value["viewportHeight"])
            ),
            fallbackViewportSize: fallbackViewportSize,
            scrollOffset: CGPoint(
                x: numberValue(value["scrollX"]),
                y: numberValue(value["scrollY"])
            )
        ) else {
            throw BrowserScreenshotError.webContentMetricsUnavailable
        }
        return metrics
    }

    @discardableResult
    private static func scroll(_ webView: WKWebView, to point: NSPoint) async throws -> CGPoint {
        let value = try await webView.callAsyncJavaScript(
            """
            const doc = document.documentElement;
            const body = document.body;
            const maximumX = Math.max(
              0,
              doc ? doc.scrollWidth - window.innerWidth : 0,
              body ? body.scrollWidth - window.innerWidth : 0
            );
            const maximumY = Math.max(
              0,
              doc ? doc.scrollHeight - window.innerHeight : 0,
              body ? body.scrollHeight - window.innerHeight : 0
            );
            const expectedX = Math.min(Math.max(0, x), maximumX);
            const expectedY = Math.min(Math.max(0, y), maximumY);
            window.scrollTo({ left: x, top: y, behavior: "instant" });
            document.documentElement?.getBoundingClientRect();
            await new Promise((resolve) => {
              requestAnimationFrame(() => requestAnimationFrame(resolve));
            });
            return {
              x: window.scrollX || 0,
              y: window.scrollY || 0,
              expectedX,
              expectedY
            };
            """,
            arguments: [
                "x": Double(point.x),
                "y": Double(point.y),
            ],
            in: nil,
            contentWorld: .page
        )
        guard let result = value as? [String: Any] else {
            throw BrowserScreenshotError.webContentMetricsUnavailable
        }
        let x = numberValue(result["x"])
        let y = numberValue(result["y"])
        let expectedX = numberValue(result["expectedX"])
        let expectedY = numberValue(result["expectedY"])
        guard x.isFinite,
              y.isFinite,
              expectedX.isFinite,
              expectedY.isFinite,
              abs(x - expectedX) <= 1,
              abs(y - expectedY) <= 1 else {
            throw BrowserScreenshotError.webContentMetricsUnavailable
        }
        return CGPoint(x: x, y: y)
    }

    private static func takeSnapshot(
        from webView: WKWebView,
        configuration: WKSnapshotConfiguration,
        renderer: BrowserViewportSnapshotRenderer? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> NSImage {
        try await BrowserScreenshotSnapshotRequest(
            webView: webView,
            configuration: configuration,
            renderer: renderer,
            timeout: timeout
        ).capture()
    }

    private static func captureVisibleViewport(
        from webView: WKWebView,
        afterScreenUpdates: Bool,
        renderer: BrowserViewportSnapshotRenderer?,
        timeout: TimeInterval? = nil
    ) async throws -> NSImage {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = afterScreenUpdates
        configuration.snapshotWidth = renderer?.snapshotWidth
        return try await takeSnapshot(
            from: webView,
            configuration: configuration,
            renderer: renderer,
            timeout: timeout
        )
    }

    private static func takeSnapshot(
        from webView: WKWebView,
        configuration: WKSnapshotConfiguration,
        renderer: BrowserViewportSnapshotRenderer? = nil,
        completion: @escaping @MainActor (Result<NSImage, Error>) -> Void
    ) {
        webView.takeSnapshot(with: configuration) { image, error in
            if let image {
                guard let renderer else {
                    completion(.success(image))
                    return
                }
                guard let normalized = renderer.normalizedImage(image) else {
                    completion(.failure(BrowserScreenshotError.invalidImageRepresentation))
                    return
                }
                completion(.success(normalized))
                return
            }

            completion(.failure(error ?? BrowserScreenshotError.emptySnapshot))
        }
    }

    private static func waitForExpectedURLIfNeeded(
        _ webView: WKWebView,
        expectedURL: URL?,
        timeout: TimeInterval
    ) async throws {
        guard let expectedURL else { return }
        let waiter = BrowserScreenshotExpectedURLWaiter(
            webView: webView,
            expectedAbsoluteString: expectedURL.absoluteString,
            timeout: timeout
        )

        try await withTaskCancellationHandler {
            try await waiter.wait()
        } onCancel: {
            Task { @MainActor in
                waiter.cancel()
            }
        }
    }

    fileprivate static func urlMatches(_ currentURL: URL, expectedAbsoluteString: String) -> Bool {
        let currentAbsoluteString = currentURL.absoluteString
        if currentAbsoluteString == expectedAbsoluteString {
            return true
        }

        guard
            var expected = URLComponents(string: expectedAbsoluteString),
            var current = URLComponents(url: currentURL, resolvingAgainstBaseURL: false)
        else {
            return false
        }

        expected.scheme = expected.scheme?.lowercased()
        current.scheme = current.scheme?.lowercased()
        expected.host = expected.host?.lowercased()
        current.host = current.host?.lowercased()

        let expectedPath = normalizedPathComponent(expected.path)
        let currentPath = normalizedPathComponent(current.path)
        let expectedPort = normalizedPortComponent(expected.port, scheme: expected.scheme)
        let currentPort = normalizedPortComponent(current.port, scheme: current.scheme)
        guard expected.scheme == current.scheme,
              expected.host == current.host,
              expectedPort == currentPort,
              expectedPath == currentPath else {
            return false
        }

        if expected.query != nil, expected.query != current.query {
            return false
        }
        if expected.fragment != nil, expected.fragment != current.fragment {
            return false
        }
        return true
    }

    private static func normalizedPathComponent(_ path: String) -> String {
        if path == "/" {
            return ""
        }
        guard path.count > 1 else { return path }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func normalizedPortComponent(_ port: Int?, scheme: String?) -> Int? {
        if let port {
            return port
        }
        switch scheme?.lowercased() {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }

    private static func viewportSnapshotRenderer(for webView: WKWebView) -> BrowserViewportSnapshotRenderer? {
        guard let viewport = (webView as? CmuxWebView)?.browserViewportModel?.viewport else {
            return nil
        }
        return BrowserViewportSnapshotRenderer(
            plan: BrowserViewportSnapshotPlan(
                viewport: viewport,
                backingScaleFactor: snapshotBackingScaleFactor(for: webView)
            )
        )
    }

    private static func viewportSnapshotRenderer(
        outputPixelSize: NSSize,
        for webView: WKWebView
    ) -> BrowserViewportSnapshotRenderer? {
        guard let plan = BrowserViewportSnapshotPlan(
            outputPixelSize: outputPixelSize,
            backingScaleFactor: snapshotBackingScaleFactor(for: webView)
        ) else {
            return nil
        }
        return BrowserViewportSnapshotRenderer(plan: plan)
    }

    private static func snapshotBackingScaleFactor(for webView: WKWebView) -> Double {
        Double(
            webView.window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 1
        )
    }

    private static var visualCaptureLayoutFlushScript: String {
        """
        (() => {
          const doc = document.documentElement;
          const body = document.body;
          if (doc) {
            doc.getBoundingClientRect();
            void doc.scrollWidth;
            void doc.scrollHeight;
          }
          if (body) {
            body.getBoundingClientRect();
            void body.scrollWidth;
            void body.scrollHeight;
          }
          return document.readyState;
        })();
        """
    }

    private static func forceAppKitLayout(for webView: WKWebView) {
        let presentationView = webView.cmuxBrowserViewportPresentationView
        webView.needsLayout = true
        presentationView.needsLayout = true
        webView.cmuxBrowserViewportAttachmentSuperview?.needsLayout = true
        webView.cmuxBrowserViewportAttachmentSuperview?.layoutSubtreeIfNeeded()
        presentationView.layoutSubtreeIfNeeded()
        webView.layoutSubtreeIfNeeded()
        presentationView.displayIfNeeded()
        webView.displayIfNeeded()
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

// Safety: BrowserScreenshotExpectedURLWaiter keeps WKWebView, KVO tokens, Timer, and CheckedContinuation main-actor-only and never sends them across threads.
@MainActor
private final class BrowserScreenshotExpectedURLWaiter: @unchecked Sendable {
    private weak var webView: WKWebView?
    private let expectedAbsoluteString: String
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<Void, Error>?
    private var urlObservation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?
    private var timeoutTimer: Timer?
    private var isCancelled = false

    init(webView: WKWebView, expectedAbsoluteString: String, timeout: TimeInterval) {
        self.webView = webView
        self.expectedAbsoluteString = expectedAbsoluteString
        self.timeout = timeout
    }

    func wait() async throws {
        try Task.checkCancellation()
        if isReady {
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            installObservers()
            if isCancelled {
                finish(.failure(CancellationError()))
                return
            }
            if isReady {
                finish(.success(()))
            }
        }
    }

    func cancel() {
        isCancelled = true
        finish(.failure(CancellationError()))
    }

    private var isReady: Bool {
        guard let webView,
              let currentURL = webView.url,
              BrowserScreenshotWebViewSnapshotter.urlMatches(
                currentURL,
                expectedAbsoluteString: expectedAbsoluteString
              ),
              !webView.isLoading else {
            return false
        }
        return true
    }

    private func installObservers() {
        guard let webView else {
            finish(.failure(BrowserScreenshotError.emptySnapshot))
            return
        }

        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finishIfReady()
                }
            }
        }
        loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finishIfReady()
                }
            }
        }
        let timer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finish(.failure(BrowserScreenshotError.emptySnapshot))
                }
            }
        }
        timeoutTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finishIfReady() {
        if isReady {
            finish(.success(()))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        urlObservation = nil
        loadingObservation = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil

        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
