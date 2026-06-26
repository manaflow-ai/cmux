import AppKit
import CmuxBrowser
import WebKit

private struct BrowserScreenshotWebContentMetrics {
    let contentSize: NSSize
    let viewportSize: NSSize
    let scrollOffset: NSPoint
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
    static func captureFullPage(
        from webView: WKWebView,
        afterScreenUpdates: Bool = true
    ) async throws -> NSImage {
        let metrics = try await webContentMetrics(for: webView)
        try BrowserScreenshotCaptureBounds.validateFullPageSize(metrics.contentSize)
        do {
            let image = try await captureSingleFullContentSnapshot(
                from: webView,
                metrics: metrics,
                afterScreenUpdates: afterScreenUpdates
            )
            if isAcceptableFullContentSnapshot(image, metrics: metrics) {
                return image
            }
        } catch {
            #if DEBUG
            cmuxDebugLog("browser.screenshot.fullPage.singleSnapshot.failed error=\(error.localizedDescription)")
            #endif
        }

        return try await captureStitchedFullPage(
            from: webView,
            metrics: metrics,
            afterScreenUpdates: afterScreenUpdates
        )
    }

    static func captureVisibleViewport(
        from webView: WKWebView,
        afterScreenUpdates: Bool = true
    ) async throws -> NSImage {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = afterScreenUpdates
        return try await takeSnapshot(from: webView, configuration: configuration)
    }

    static func captureVisibleViewport(
        from webView: WKWebView,
        afterScreenUpdates: Bool = true,
        completion: @escaping (Result<NSImage, Error>) -> Void
    ) {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = afterScreenUpdates
        takeSnapshot(from: webView, configuration: configuration, completion: completion)
    }

    private static func captureSingleFullContentSnapshot(
        from webView: WKWebView,
        metrics: BrowserScreenshotWebContentMetrics,
        afterScreenUpdates: Bool
    ) async throws -> NSImage {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = afterScreenUpdates
        configuration.snapshotWidth = nil
        configuration.rect = NSRect(origin: .zero, size: metrics.contentSize)
        return try await takeSnapshot(from: webView, configuration: configuration)
    }

    private static func captureStitchedFullPage(
        from webView: WKWebView,
        metrics: BrowserScreenshotWebContentMetrics,
        afterScreenUpdates: Bool
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

        let placement = BrowserScreenshotTilePlacement(contentSize: contentSize, viewportSize: viewportSize)
        let xPositions = placement.horizontalTileOrigins
        let yPositions = placement.verticalTileOrigins
        var captureError: Error?
        var didCaptureTile = false
        let output = blankImage(size: contentSize)

        do {
            for y in yPositions {
                for x in xPositions {
                    try await scroll(webView, to: NSPoint(x: x, y: y))
                    let tile = try await captureVisibleViewport(
                        from: webView,
                        afterScreenUpdates: afterScreenUpdates
                    )
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

    static func withOffscreenRenderHost<T>(
        _ webView: WKWebView,
        viewportSize: NSSize,
        expectedURL: URL?,
        operation: () async throws -> T
    ) async throws -> T {
        let previousSuperview = webView.superview
        let previousSubviews = previousSuperview?.subviews ?? []
        let previousIndex = previousSubviews.firstIndex(of: webView)
        let previousFrame = webView.frame
        let previousBounds = webView.bounds
        let previousAutoresizingMask = webView.autoresizingMask
        let previousTranslatesAutoresizingMaskIntoConstraints = webView.translatesAutoresizingMaskIntoConstraints
        let restoreAnchor: NSView?
        let restorePosition: NSWindow.OrderingMode
        if let previousIndex, previousIndex > 0 {
            restoreAnchor = previousSubviews[previousIndex - 1]
            restorePosition = .above
        } else if let previousIndex, previousIndex == 0, previousSubviews.count > 1 {
            restoreAnchor = previousSubviews[1]
            restorePosition = .below
        } else {
            restoreAnchor = nil
            restorePosition = .above
        }

        let normalizedSize = normalizedViewportSize(viewportSize)
        let frame = NSRect(
            x: -100_000 - normalizedSize.width,
            y: -100_000 - normalizedSize.height,
            width: normalizedSize.width,
            height: normalizedSize.height
        )
        let window = BrowserScreenshotOffscreenRenderPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.browserVisualAutomationRender")
        window.hasShadow = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary, .canJoinAllSpaces]
        window.isExcludedFromWindowsMenu = true

        let contentView = NSView(frame: NSRect(origin: .zero, size: normalizedSize))
        contentView.wantsLayer = true
        webView.removeFromSuperview()
        webView.frame = contentView.bounds
        webView.autoresizingMask = [.width, .height]
        contentView.addSubview(webView)
        window.contentView = contentView
        window.orderFrontRegardless()

        defer {
            restoreWebView(
                webView,
                to: previousSuperview,
                frame: previousFrame,
                bounds: previousBounds,
                autoresizingMask: previousAutoresizingMask,
                translatesAutoresizingMaskIntoConstraints: previousTranslatesAutoresizingMaskIntoConstraints,
                anchor: restoreAnchor,
                position: restorePosition
            )
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        try await prepareForVisualCapture(webView, expectedURL: expectedURL)
        return try await operation()
    }

    static func withOffscreenRenderHost<T>(
        _ webView: WKWebView,
        viewportSize: NSSize,
        expectedURL: URL?,
        timeout: TimeInterval,
        operation: @escaping (@escaping (Result<T, Error>) -> Void) -> Void,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        let previousSuperview = webView.superview
        let previousSubviews = previousSuperview?.subviews ?? []
        let previousIndex = previousSubviews.firstIndex(of: webView)
        let previousFrame = webView.frame
        let previousBounds = webView.bounds
        let previousAutoresizingMask = webView.autoresizingMask
        let previousTranslatesAutoresizingMaskIntoConstraints = webView.translatesAutoresizingMaskIntoConstraints
        let restoreAnchor: NSView?
        let restorePosition: NSWindow.OrderingMode
        if let previousIndex, previousIndex > 0 {
            restoreAnchor = previousSubviews[previousIndex - 1]
            restorePosition = .above
        } else if let previousIndex, previousIndex == 0, previousSubviews.count > 1 {
            restoreAnchor = previousSubviews[1]
            restorePosition = .below
        } else {
            restoreAnchor = nil
            restorePosition = .above
        }

        let normalizedSize = normalizedViewportSize(viewportSize)
        let frame = NSRect(
            x: -100_000 - normalizedSize.width,
            y: -100_000 - normalizedSize.height,
            width: normalizedSize.width,
            height: normalizedSize.height
        )
        let window = BrowserScreenshotOffscreenRenderPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.browserVisualAutomationRender")
        window.hasShadow = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary, .canJoinAllSpaces]
        window.isExcludedFromWindowsMenu = true

        let contentView = NSView(frame: NSRect(origin: .zero, size: normalizedSize))
        contentView.wantsLayer = true
        webView.removeFromSuperview()
        webView.frame = contentView.bounds
        webView.autoresizingMask = [.width, .height]
        contentView.addSubview(webView)
        window.contentView = contentView
        window.orderFrontRegardless()

        var didFinish = false
        var timeoutTimer: Timer?
        let finish: (Result<T, Error>) -> Void = { result in
            guard !didFinish else { return }
            didFinish = true
            timeoutTimer?.invalidate()
            timeoutTimer = nil
            restoreWebView(
                webView,
                to: previousSuperview,
                frame: previousFrame,
                bounds: previousBounds,
                autoresizingMask: previousAutoresizingMask,
                translatesAutoresizingMaskIntoConstraints: previousTranslatesAutoresizingMaskIntoConstraints,
                anchor: restoreAnchor,
                position: restorePosition
            )
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            completion(result)
        }

        timeoutTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
            finish(.failure(BrowserScreenshotError.emptySnapshot))
        }

        prepareForVisualCapture(webView, expectedURL: expectedURL) { result in
            switch result {
            case .success:
                operation(finish)
            case .failure(let error):
                finish(.failure(error))
            }
        }
    }

    static func prepareForVisualCapture(_ webView: WKWebView, expectedURL: URL?) async throws {
        try await waitForExpectedURLIfNeeded(webView, expectedURL: expectedURL)

        forceAppKitLayout(for: webView)

        do {
            _ = try await webView.evaluateJavaScript(visualCaptureLayoutFlushScript, contentWorld: .page)
        } catch {
            #if DEBUG
            cmuxDebugLog("browser.screenshot.prepare.failed error=\(error.localizedDescription)")
            #endif
        }

        forceAppKitLayout(for: webView)
    }

    static func prepareForVisualCapture(
        _ webView: WKWebView,
        expectedURL: URL?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        waitForExpectedURLIfNeeded(webView, expectedURL: expectedURL) { result in
            switch result {
            case .success:
                forceAppKitLayout(for: webView)
                webView.evaluateJavaScript(visualCaptureLayoutFlushScript) { _, error in
                    if let error {
                        #if DEBUG
                        cmuxDebugLog("browser.screenshot.prepare.failed error=\(error.localizedDescription)")
                        #endif
                    }
                    forceAppKitLayout(for: webView)
                    completion(.success(()))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
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
        guard let rects = BrowserScreenshotTilePlacement(
            contentSize: contentSize,
            viewportSize: viewportSize
        ).drawRects(tileSize: tile.size, origin: origin) else {
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

    private static func takeSnapshot(
        from webView: WKWebView,
        configuration: WKSnapshotConfiguration,
        completion: @escaping (Result<NSImage, Error>) -> Void
    ) {
        webView.takeSnapshot(with: configuration) { image, error in
            if let image {
                completion(.success(image))
                return
            }

            completion(.failure(error ?? BrowserScreenshotError.emptySnapshot))
        }
    }

    private static func waitForExpectedURLIfNeeded(_ webView: WKWebView, expectedURL: URL?) async throws {
        guard let expectedURL else { return }
        let waiter = BrowserScreenshotExpectedURLWaiter(
            webView: webView,
            expectedAbsoluteString: expectedURL.absoluteString,
            timeout: 5.0
        )

        try await withTaskCancellationHandler {
            try await waiter.wait()
        } onCancel: {
            Task { @MainActor in
                waiter.cancel()
            }
        }
    }

    private static func waitForExpectedURLIfNeeded(
        _ webView: WKWebView,
        expectedURL: URL?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let expectedURL else {
            completion(.success(()))
            return
        }
        let waiter = BrowserScreenshotExpectedURLWaiter(
            webView: webView,
            expectedAbsoluteString: expectedURL.absoluteString,
            timeout: 5.0
        )
        waiter.wait { [waiter] result in
            _ = waiter
            completion(result)
        }
    }

    private static func normalizedViewportSize(_ viewportSize: NSSize) -> NSSize {
        let fallback = NSSize(width: 1280, height: 720)
        let width = viewportSize.width.isFinite && viewportSize.width > 1 ? viewportSize.width : fallback.width
        let height = viewportSize.height.isFinite && viewportSize.height > 1 ? viewportSize.height : fallback.height
        return NSSize(
            width: min(max(width, 1), 4096),
            height: min(max(height, 1), 4096)
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
        webView.needsLayout = true
        webView.superview?.needsLayout = true
        webView.superview?.layoutSubtreeIfNeeded()
        webView.layoutSubtreeIfNeeded()
        webView.superview?.displayIfNeeded()
        webView.displayIfNeeded()
    }

    private static func restoreWebView(
        _ webView: WKWebView,
        to previousSuperview: NSView?,
        frame: NSRect,
        bounds: NSRect,
        autoresizingMask: NSView.AutoresizingMask,
        translatesAutoresizingMaskIntoConstraints: Bool,
        anchor: NSView?,
        position: NSWindow.OrderingMode
    ) {
        webView.removeFromSuperview()
        if let previousSuperview {
            if let anchor, anchor.superview === previousSuperview {
                previousSuperview.addSubview(webView, positioned: position, relativeTo: anchor)
            } else {
                previousSuperview.addSubview(webView)
            }
            webView.frame = frame
            webView.bounds = bounds
            webView.autoresizingMask = autoresizingMask
            webView.translatesAutoresizingMaskIntoConstraints = translatesAutoresizingMaskIntoConstraints
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

@MainActor
private final class BrowserScreenshotOffscreenRenderPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// Safety: BrowserScreenshotExpectedURLWaiter keeps WKWebView, KVO tokens, Timer, and CheckedContinuation main-actor-only and never sends them across threads.
@MainActor
private final class BrowserScreenshotExpectedURLWaiter: @unchecked Sendable {
    private weak var webView: WKWebView?
    private let expectedAbsoluteString: String
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<Void, Error>?
    private var completion: ((Result<Void, Error>) -> Void)?
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

    func wait(completion: @escaping (Result<Void, Error>) -> Void) {
        if isReady {
            completion(.success(()))
            return
        }

        self.completion = completion
        installObservers()
        if isCancelled {
            finish(.failure(CancellationError()))
            return
        }
        if isReady {
            finish(.success(()))
        }
    }

    func cancel() {
        isCancelled = true
        finish(.failure(CancellationError()))
    }

    private var isReady: Bool {
        guard let webView,
              let currentURL = webView.url,
              ExpectedURLMatcher(expectedAbsoluteString: expectedAbsoluteString)
                .matches(currentURL),
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
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finish(.failure(BrowserScreenshotError.emptySnapshot))
                }
            }
        }
    }

    private func finishIfReady() {
        if isReady {
            finish(.success(()))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard continuation != nil || completion != nil else { return }
        let continuation = self.continuation
        let completion = self.completion
        self.continuation = nil
        self.completion = nil
        urlObservation = nil
        loadingObservation = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil

        if let continuation {
            switch result {
            case .success:
                continuation.resume()
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
        completion?(result)
    }
}
