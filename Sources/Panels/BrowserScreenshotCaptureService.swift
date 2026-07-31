import AppKit
import CmuxBrowser
import WebKit

/// Owns synchronized, DOM-attested capture of one browser viewport.
@MainActor
struct BrowserScreenshotCaptureService {
    typealias Synchronizer = @MainActor (_ isRetry: Bool) async -> Void
    typealias ProbeCollector = @MainActor () async -> BrowserScreenshotProbeSet?
    typealias SnapshotProvider = @MainActor () async throws -> NSImage
    typealias PixelSourceProvider = @MainActor (
        NSImage
    ) -> (any BrowserScreenshotPixelSource)?

    private let maximumAttempts: Int
    private let synchronize: Synchronizer
    private let collectProbes: ProbeCollector
    private let snapshot: SnapshotProvider
    private let makePixelSource: PixelSourceProvider
    private let verifier: BrowserScreenshotFrameVerifier

    init(
        webView: WKWebView,
        presentation: BrowserScreenshotPresentation,
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
        var lastMismatch: (probe: BrowserScreenshotProbe, count: Int)?

        for attempt in 1...maximumAttempts {
            try Task.checkCancellation()
            await synchronize(attempt > 1)
            try Task.checkCancellation()
            let before = await collectProbes()
            try Task.checkCancellation()
            let image = try await snapshot()
            try Task.checkCancellation()
            let after = await collectProbes()
            try Task.checkCancellation()

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
