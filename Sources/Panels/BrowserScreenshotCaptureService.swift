import AppKit
import CmuxBrowser
import WebKit

/// Owns synchronized, DOM-attested capture of one browser viewport.
@MainActor
struct BrowserScreenshotCaptureService {
    enum Presentation: Equatable {
        /// A view owned by a user-visible pane and left in its existing host.
        case onscreen
        /// A hidden view temporarily attached to the offscreen render host.
        ///
        /// Waiting for screen updates here can stall forever because AppKit has
        /// no displayed window update to deliver.
        case offscreen

        func afterScreenUpdates(windowIsVisible: Bool) -> Bool {
            self == .onscreen && windowIsVisible
        }

        var usesOffscreenRenderHost: Bool {
            self == .offscreen
        }

        func waitsForAnimationFrame(isRetry: Bool) -> Bool {
            if isRetry {
                return true
            }
            switch self {
            case .onscreen:
                return true
            case .offscreen:
                return false
            }
        }

        static func resolve(
            isVisibleInUI: Bool,
            isAttachedToWindow: Bool,
            isHiddenOrHasHiddenAncestor: Bool,
            boundsSize: NSSize
        ) -> Self {
            guard isVisibleInUI,
                  isAttachedToWindow,
                  !isHiddenOrHasHiddenAncestor,
                  boundsSize.width > 1,
                  boundsSize.height > 1 else {
                return .offscreen
            }
            return .onscreen
        }
    }

    typealias Synchronizer = @MainActor (_ isRetry: Bool) async -> Void
    typealias ProbeCollector = @MainActor () async -> BrowserScreenshotFrameVerifier.ProbeSet?
    typealias SnapshotProvider = @MainActor () async throws -> NSImage
    typealias PixelSourceProvider = @MainActor (
        NSImage
    ) -> (any BrowserScreenshotFrameVerifier.PixelSource)?

    private let maximumAttempts: Int
    private let synchronize: Synchronizer
    private let collectProbes: ProbeCollector
    private let snapshot: SnapshotProvider
    private let makePixelSource: PixelSourceProvider
    private let verifier: BrowserScreenshotFrameVerifier

    init(
        webView: WKWebView,
        presentation: Presentation,
        maximumAttempts: Int = 2
    ) {
        let probeCollector = BrowserScreenshotDOMProbeCollector(webView: webView)
        self.init(
            maximumAttempts: maximumAttempts,
            synchronize: { isRetry in
                await probeCollector.synchronize(
                    waitForAnimationFrame: presentation.waitsForAnimationFrame(
                        isRetry: isRetry
                    )
                )
            },
            collectProbes: {
                await probeCollector.collect()
            },
            snapshot: {
                try await BrowserScreenshotWebViewSnapshotter.captureVisibleViewport(
                    from: webView,
                    afterScreenUpdates: presentation.afterScreenUpdates(
                        windowIsVisible: webView.window?.occlusionState.contains(.visible) == true
                    )
                )
            },
            makePixelSource: {
                BrowserScreenshotBitmapPixelSource(image: $0)
            }
        )
    }

    init(
        maximumAttempts: Int = 2,
        synchronize: @escaping Synchronizer,
        collectProbes: @escaping ProbeCollector,
        snapshot: @escaping SnapshotProvider,
        makePixelSource: @escaping PixelSourceProvider,
        verifier: BrowserScreenshotFrameVerifier = .init()
    ) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.synchronize = synchronize
        self.collectProbes = collectProbes
        self.snapshot = snapshot
        self.makePixelSource = makePixelSource
        self.verifier = verifier
    }

    func capture() async throws -> NSImage {
        var lastMismatch: (probe: BrowserScreenshotFrameVerifier.Probe, count: Int)?

        for attempt in 1...maximumAttempts {
            try Task.checkCancellation()
            await synchronize(attempt > 1)
            try Task.checkCancellation()
            let before = await collectProbes()
            let image = try await snapshot()
            try Task.checkCancellation()
            let after = await collectProbes()

            guard let before,
                  let after,
                  let pixels = makePixelSource(image) else {
                return image
            }

            switch verifier.verify(before: before, after: after, pixels: pixels) {
            case .accepted:
                return image
            case .mismatch(let probe, let count):
                lastMismatch = (probe, count)
#if DEBUG
                cmuxDebugLog(
                    "browser.screenshot.verify.retry attempt=\(attempt) " +
                    "probe=\(probe.identifier) mismatches=\(count)"
                )
#endif
            }
        }

        guard let lastMismatch else {
            throw BrowserScreenshotError.emptySnapshot
        }
        // A plausible-but-wrong frame is more damaging to automated visual QA
        // than an explicit failure that the caller can diagnose and retry.
        throw BrowserScreenshotError.renderedContentMismatch(
            rect: lastMismatch.probe.rect,
            attempts: maximumAttempts,
            mismatchCount: lastMismatch.count
        )
    }
}
