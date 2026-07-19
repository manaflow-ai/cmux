import AppKit
import CmuxBrowser
import WebKit

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
        if let snapshotRect = metrics.untransformedFullContentSnapshotRect(in: webView.bounds) {
            do {
                let image = try await captureSingleFullContentSnapshot(
                    from: webView,
                    snapshotRect: snapshotRect,
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
        let renderer = viewportSnapshotRenderer(for: webView)
        return try await captureVisibleViewport(
            from: webView,
            afterScreenUpdates: afterScreenUpdates,
            renderer: renderer
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
        afterScreenUpdates: Bool
    ) async throws -> NSImage {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = afterScreenUpdates
        configuration.snapshotWidth = nil
        configuration.rect = snapshotRect
        return try await takeSnapshot(from: webView, configuration: configuration)
    }

    private static func captureStitchedFullPage(
        from webView: WKWebView,
        metrics: BrowserViewportContentMetrics,
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
                    guard let origin = tilePlan.origin(column: column, row: row) else {
                        throw BrowserScreenshotError.webContentMetricsUnavailable
                    }
                    try await scroll(webView, to: origin)
                    let tile = try await captureVisibleViewport(
                        from: webView,
                        afterScreenUpdates: afterScreenUpdates,
                        renderer: tileRenderer
                    )
                    drawTile(
                        tile,
                        at: origin,
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
        let presentationView = webView.cmuxBrowserViewportPresentationView
        let previousSuperview = presentationView.superview
        let previousSubviews = previousSuperview?.subviews ?? []
        let previousIndex = previousSubviews.firstIndex(of: presentationView)
        let previousFrame = presentationView.frame
        let previousBounds = presentationView.bounds
        let previousAutoresizingMask = presentationView.autoresizingMask
        let previousTranslatesAutoresizingMaskIntoConstraints = presentationView.translatesAutoresizingMaskIntoConstraints
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
        presentationView.removeFromSuperview()
        contentView.addSubview(presentationView)
        webView.cmuxApplyBrowserViewportLayout(in: contentView.bounds)
        window.contentView = contentView
        window.orderFrontRegardless()

        defer {
            restorePresentationView(
                presentationView,
                webView: webView,
                from: contentView,
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
        let presentationView = webView.cmuxBrowserViewportPresentationView
        let previousSuperview = presentationView.superview
        let previousSubviews = previousSuperview?.subviews ?? []
        let previousIndex = previousSubviews.firstIndex(of: presentationView)
        let previousFrame = presentationView.frame
        let previousBounds = presentationView.bounds
        let previousAutoresizingMask = presentationView.autoresizingMask
        let previousTranslatesAutoresizingMaskIntoConstraints = presentationView.translatesAutoresizingMaskIntoConstraints
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
        presentationView.removeFromSuperview()
        contentView.addSubview(presentationView)
        webView.cmuxApplyBrowserViewportLayout(in: contentView.bounds)
        window.contentView = contentView
        window.orderFrontRegardless()

        var didFinish = false
        var timeoutTimer: Timer?
        let finish: (Result<T, Error>) -> Void = { result in
            guard !didFinish else { return }
            didFinish = true
            timeoutTimer?.invalidate()
            timeoutTimer = nil
            restorePresentationView(
                presentationView,
                webView: webView,
                from: contentView,
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
            finish(.failure(BrowserScreenshotError.automationTimedOut))
        }
        prepareForVisualCapture(webView, expectedURL: expectedURL) { result in
            switch result {
            case .success:
                guard !didFinish else { return }
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
        metrics: BrowserViewportContentMetrics
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
        configuration: WKSnapshotConfiguration,
        renderer: BrowserViewportSnapshotRenderer? = nil
    ) async throws -> NSImage {
        try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                if let image {
                    guard let renderer else {
                        continuation.resume(returning: image)
                        return
                    }
                    guard let normalized = renderer.normalizedImage(image) else {
                        continuation.resume(throwing: BrowserScreenshotError.invalidImageRepresentation)
                        return
                    }
                    continuation.resume(returning: normalized)
                    return
                }

                continuation.resume(throwing: error ?? BrowserScreenshotError.emptySnapshot)
            }
        }
    }

    private static func captureVisibleViewport(
        from webView: WKWebView,
        afterScreenUpdates: Bool,
        renderer: BrowserViewportSnapshotRenderer?
    ) async throws -> NSImage {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = afterScreenUpdates
        configuration.snapshotWidth = renderer?.snapshotWidth
        return try await takeSnapshot(
            from: webView,
            configuration: configuration,
            renderer: renderer
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

    private static func normalizedViewportSize(_ viewportSize: NSSize) -> NSSize {
        let fallback = NSSize(width: 1280, height: 720)
        let width = viewportSize.width.isFinite && viewportSize.width > 1 ? viewportSize.width : fallback.width
        let height = viewportSize.height.isFinite && viewportSize.height > 1 ? viewportSize.height : fallback.height
        return NSSize(
            width: min(max(width, 1), 4096),
            height: min(max(height, 1), 4096)
        )
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

    private static func restorePresentationView(
        _ presentationView: NSView,
        webView: WKWebView,
        from temporarySuperview: NSView,
        to previousSuperview: NSView?,
        frame previousFrame: NSRect,
        bounds previousBounds: NSRect,
        autoresizingMask previousAutoresizingMask: NSView.AutoresizingMask,
        translatesAutoresizingMaskIntoConstraints previousTranslatesAutoresizingMaskIntoConstraints: Bool,
        anchor: NSView?,
        position: NSWindow.OrderingMode
    ) {
        let policy = BrowserViewportRestorationPolicy(
            temporaryHostIsCurrent: presentationView.superview === temporarySuperview,
            hasPreviousHost: previousSuperview != nil,
            hasVisibleWebKitCompanion: previousSuperview?
                .browserPortalHasVisibleWebKitCompanionSubview(for: webView) ?? false
        )
        guard policy.shouldRestorePreviousHost else { return }

        presentationView.removeFromSuperview()
        if let previousSuperview {
            if let anchor, anchor.superview === previousSuperview {
                previousSuperview.addSubview(presentationView, positioned: position, relativeTo: anchor)
            } else {
                previousSuperview.addSubview(presentationView)
            }
        }

        if policy.shouldPreservePreviousGeometry {
            presentationView.frame = previousFrame
            presentationView.bounds = previousBounds
            presentationView.autoresizingMask = previousAutoresizingMask
            presentationView.translatesAutoresizingMaskIntoConstraints =
                previousTranslatesAutoresizingMaskIntoConstraints
        } else if let previousSuperview {
            webView.cmuxApplyBrowserViewportLayout(in: previousSuperview.bounds)
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
