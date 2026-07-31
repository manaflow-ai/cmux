import AppKit
import CmuxBrowser
import WebKit

/// Owns synchronized, DOM-attested capture of one browser viewport.
@MainActor
struct BrowserScreenshotCaptureService {
    enum Presentation {
        /// A genuinely visible view, where WebKit can wait for recent screen updates.
        case onscreen
        /// A hidden view temporarily attached to the offscreen render host.
        ///
        /// Waiting for screen updates here can stall forever because AppKit has
        /// no displayed window update to deliver.
        case offscreen

        fileprivate var afterScreenUpdates: Bool {
            switch self {
            case .onscreen:
                true
            case .offscreen:
                false
            }
        }

        fileprivate var waitsForAnimationFrame: Bool {
            switch self {
            case .onscreen:
                true
            case .offscreen:
                false
            }
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
                    waitForAnimationFrame: presentation.waitsForAnimationFrame || isRetry
                )
            },
            collectProbes: {
                await probeCollector.collect()
            },
            snapshot: {
                try await BrowserScreenshotWebViewSnapshotter.captureVisibleViewport(
                    from: webView,
                    afterScreenUpdates: presentation.afterScreenUpdates
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
        throw BrowserScreenshotError.renderedContentMismatch(
            rect: lastMismatch.probe.rect,
            attempts: maximumAttempts,
            mismatchCount: lastMismatch.count
        )
    }
}
