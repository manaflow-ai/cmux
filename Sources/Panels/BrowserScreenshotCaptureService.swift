import AppKit
import CmuxBrowser
import CmuxFoundation
import WebKit

/// Owns synchronized, DOM-attested capture of one browser viewport.
@MainActor
struct BrowserScreenshotCaptureService {
    nonisolated static let defaultMaximumAttempts =
        BrowserScreenshotTimingBudget().maximumAttempts
    nonisolated static let automationLeaseTimeout =
        BrowserScreenshotTimingBudget().captureLeaseTimeout
    nonisolated static let socketResponseTimeout =
        BrowserScreenshotTimingBudget().socketResponseTimeout

    // Waiting for a displayed update can stall after window occlusion. The
    // bounded double-rAF/AppKit flush is the synchronization contract instead.
    private static let waitsForScreenUpdates = false

    typealias Synchronizer = @MainActor (
        _ isRetry: Bool
    ) async throws -> BrowserScreenshotSynchronizationOutcome
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
        timingBudget: BrowserScreenshotTimingBudget = .init(),
        maximumAttempts: Int? = nil
    ) {
        let probeCollector = BrowserScreenshotDOMProbeCollector(
            webView: webView,
            animationFrameTimeout: timingBudget.synchronizationAllowance,
            synchronizationJavaScriptTimeout: timingBudget.synchronizationAllowance,
            javaScriptTimeout: timingBudget.probeCollectionAllowance
        )
        self.init(
            maximumAttempts: maximumAttempts ?? timingBudget.maximumAttempts,
            synchronize: { isRetry in
                try await probeCollector.synchronize(
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
                    afterScreenUpdates: Self.waitsForScreenUpdates,
                    timeout: timingBudget.snapshotCompletionAllowance
                )
            },
            makePixelSource: {
                BrowserScreenshotBitmapPixelSource(image: $0)
            }
        )
    }

    init(
        maximumAttempts: Int = Self.defaultMaximumAttempts,
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
        var attempt = 1
        while true {
            try Task.checkCancellation()
            let before = await collectProbes()
            try Task.checkCancellation()
            let synchronization = try await synchronize(attempt > 1)
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
                guard attempt == maximumAttempts else {
#if DEBUG
                    cmuxDebugLog(
                        "browser.screenshot.verify.retry attempt=\(attempt) " +
                        "probe=\(probe.identifier) mismatches=\(count)"
                    )
#endif
                    attempt += 1
                    continue
                }
                guard synchronization == .completed else {
                    throw BrowserScreenshotError.automationTimedOut
                }
                // A plausible-but-wrong frame is more damaging to automated visual QA
                // than an explicit failure that the caller can diagnose and retry.
                throw BrowserScreenshotError.renderedContentMismatch(
                    rect: probe.rect,
                    attempts: maximumAttempts,
                    mismatchCount: count
                )
            }
        }
    }
}
