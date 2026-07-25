import AppKit
import Foundation
import WebKit

/// Bounds design-mode screenshot capture and releases awaiters on lifecycle cancellation.
@MainActor
final class BrowserDesignModeScreenshotEvaluator {
    private typealias PendingCancellation = (
        continuation: CheckedContinuation<NSImage, any Error>,
        captureTask: Task<Void, Never>?
    )

    typealias Capture = @MainActor (
        WKWebView,
        @escaping @MainActor (Result<NSImage, any Error>) -> Void
    ) -> Void
    typealias AsyncCapture = @MainActor (WKWebView) async throws -> NSImage
    typealias ProgressiveCapture = @MainActor (
        WKWebView,
        @escaping @MainActor () -> Void
    ) async throws -> NSImage
    typealias DocumentRectCapture = @MainActor (WKWebView, NSRect) async throws -> NSImage

    private let timeout: TimeInterval
    private let cleanupTimeout: TimeInterval
    private let visibleViewportCapture: Capture
    private let fullPageCapture: ProgressiveCapture
    private let documentRectCapture: DocumentRectCapture
    private let fullPageUsesInactivityTimeout: Bool
    private var continuations: [UUID: CheckedContinuation<NSImage, any Error>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var captureTasks: [UUID: Task<Void, Never>] = [:]

    init(timeout: TimeInterval = 5, cleanupTimeout: TimeInterval = 2) {
        self.timeout = timeout
        self.cleanupTimeout = cleanupTimeout
        visibleViewportCapture = { webView, completion in
            BrowserScreenshotWebViewSnapshotter.captureVisibleViewport(
                from: webView,
                completion: completion
            )
        }
        fullPageCapture = { webView, onProgress in
            try await BrowserScreenshotWebViewSnapshotter.captureBoundedFullPageOverview(
                from: webView,
                maximumPixelCount: BrowserScreenshotPasteboardWriter.maximumDesignModeArtifactPixelCount,
                onProgress: onProgress
            )
        }
        documentRectCapture = { webView, rect in
            try await BrowserScreenshotWebViewSnapshotter.captureDocumentRect(
                rect,
                from: webView
            )
        }
        fullPageUsesInactivityTimeout = true
    }

    convenience init(
        timeout: TimeInterval,
        cleanupTimeout: TimeInterval = 2,
        capture: @escaping Capture
    ) {
        self.init(
            timeout: timeout,
            cleanupTimeout: cleanupTimeout,
            visibleViewportCapture: capture,
            fullPageCapture: { webView in
                try await withCheckedThrowingContinuation { continuation in
                    capture(webView) { result in
                        continuation.resume(with: result)
                    }
                }
            }
        )
    }

    init(
        timeout: TimeInterval,
        cleanupTimeout: TimeInterval = 2,
        visibleViewportCapture: @escaping Capture,
        fullPageCapture: @escaping AsyncCapture,
        documentRectCapture: @escaping DocumentRectCapture = { webView, rect in
            try await BrowserScreenshotWebViewSnapshotter.captureDocumentRect(
                rect,
                from: webView
            )
        }
    ) {
        self.timeout = timeout
        self.cleanupTimeout = cleanupTimeout
        self.visibleViewportCapture = visibleViewportCapture
        self.fullPageCapture = { webView, _ in
            try await fullPageCapture(webView)
        }
        self.documentRectCapture = documentRectCapture
        fullPageUsesInactivityTimeout = false
    }

    init(
        timeout: TimeInterval,
        cleanupTimeout: TimeInterval = 2,
        visibleViewportCapture: @escaping Capture,
        fullPageCapture: @escaping ProgressiveCapture,
        documentRectCapture: @escaping DocumentRectCapture = { webView, rect in
            try await BrowserScreenshotWebViewSnapshotter.captureDocumentRect(
                rect,
                from: webView
            )
        }
    ) {
        self.timeout = timeout
        self.cleanupTimeout = cleanupTimeout
        self.visibleViewportCapture = visibleViewportCapture
        self.fullPageCapture = fullPageCapture
        self.documentRectCapture = documentRectCapture
        fullPageUsesInactivityTimeout = true
    }

    func captureVisibleViewport(from webView: WKWebView) async throws -> NSImage {
        try await captureImage(usesTimeout: true) { [visibleViewportCapture] operationID in
            visibleViewportCapture(webView) { [weak self] result in
                self?.finish(operationID, with: result)
            }
        }
    }

    func captureFullPage(from webView: WKWebView) async throws -> NSImage {
        try await captureImage(
            usesTimeout: fullPageUsesInactivityTimeout
        ) { [weak self, fullPageCapture] operationID in
            guard let self else { return }
            self.captureTasks[operationID] = Task { @MainActor [weak self] in
                do {
                    let image = try await fullPageCapture(webView) { [weak self] in
                        self?.resetTimeout(operationID)
                    }
                    self?.finish(operationID, returning: image)
                } catch {
                    self?.finish(operationID, throwing: error)
                }
            }
        }
    }

    func captureDocumentRect(_ rect: NSRect, from webView: WKWebView) async throws -> NSImage {
        try await captureImage(usesTimeout: true) { [weak self, documentRectCapture] operationID in
            guard let self else { return }
            self.captureTasks[operationID] = Task { @MainActor [weak self] in
                do {
                    let image = try await documentRectCapture(webView, rect)
                    self?.finish(operationID, returning: image)
                } catch {
                    self?.finish(operationID, throwing: error)
                }
            }
        }
    }

    private func captureImage(
        usesTimeout: Bool,
        start: @escaping @MainActor (_ operationID: UUID) -> Void
    ) async throws -> NSImage {
        let operationID = UUID()
        do {
            let image = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    continuations[operationID] = continuation
                    if usesTimeout {
                        resetTimeout(operationID)
                    }
                    start(operationID)
                }
            } onCancel: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.cancelAndFinish(
                        operationID,
                        throwing: CancellationError()
                    )
                }
            }
            try Task.checkCancellation()
            return image
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    private func resetTimeout(_ operationID: UUID) {
        guard continuations[operationID] != nil else { return }
        timeoutTasks.removeValue(forKey: operationID)?.cancel()
        timeoutTasks[operationID] = Task { @MainActor [weak self, timeout] in
            // This is a bounded operation deadline, not a synchronization delay.
            do {
                try await ContinuousClock().sleep(for: .seconds(timeout))
            } catch {
                return
            }
            await self?.cancelAndFinish(
                operationID,
                throwing: BrowserDesignModeError.operationTimedOut
            )
        }
    }

    func cancelAll() {
        let cancellations = Array(continuations.keys).compactMap {
            beginCancellation($0)
        }
        for cancellation in cancellations {
            Task { @MainActor [cleanupTimeout] in
                await Self.resumeAfterCleanup(
                    cancellation,
                    throwing: CancellationError(),
                    cleanupTimeout: cleanupTimeout
                )
            }
        }
    }

    private func finish(_ operationID: UUID, with result: Result<NSImage, any Error>) {
        switch result {
        case .success(let image):
            finish(operationID, returning: image)
        case .failure(let error):
            finish(operationID, throwing: error)
        }
    }

    private func finish(_ operationID: UUID, returning image: NSImage) {
        guard let continuation = removeOperation(operationID) else { return }
        continuation.resume(returning: image)
    }

    private func finish(_ operationID: UUID, throwing error: any Error) {
        guard let continuation = removeOperation(operationID) else { return }
        continuation.resume(throwing: error)
    }

    /// Timeout and caller cancellation must not release the awaiting capture
    /// owner until scrolling capture has restored the page and fully exited.
    private func cancelAndFinish(
        _ operationID: UUID,
        throwing error: any Error
    ) async {
        guard let cancellation = beginCancellation(operationID) else { return }
        await Self.resumeAfterCleanup(
            cancellation,
            throwing: error,
            cleanupTimeout: cleanupTimeout
        )
    }

    private func beginCancellation(
        _ operationID: UUID
    ) -> PendingCancellation? {
        timeoutTasks.removeValue(forKey: operationID)?.cancel()
        guard let continuation = continuations.removeValue(forKey: operationID) else { return nil }
        let captureTask = captureTasks.removeValue(forKey: operationID)
        captureTask?.cancel()
        return (continuation, captureTask)
    }

    private static func resumeAfterCleanup(
        _ cancellation: PendingCancellation,
        throwing error: any Error,
        cleanupTimeout: TimeInterval
    ) async {
        let cleanupCompleted: Bool
        if let captureTask = cancellation.captureTask {
            cleanupCompleted = await BrowserDesignModeCaptureCleanupWaiter.wait(
                for: captureTask,
                timeout: cleanupTimeout
            )
        } else {
            cleanupCompleted = true
        }
        // An uncooperative WebKit callback must not defeat the timeout or let
        // the caller start selection fallback against a page still in capture.
        cancellation.continuation.resume(
            throwing: cleanupCompleted ? error : CancellationError()
        )
    }

    private func removeOperation(
        _ operationID: UUID
    ) -> CheckedContinuation<NSImage, any Error>? {
        timeoutTasks.removeValue(forKey: operationID)?.cancel()
        captureTasks.removeValue(forKey: operationID)?.cancel()
        return continuations.removeValue(forKey: operationID)
    }
}

@MainActor
private final class BrowserDesignModeCaptureCleanupWaiter {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?

    static func wait(
        for captureTask: Task<Void, Never>,
        timeout: TimeInterval
    ) async -> Bool {
        let waiter = BrowserDesignModeCaptureCleanupWaiter()
        return await waiter.wait(for: captureTask, timeout: timeout)
    }

    private func wait(
        for captureTask: Task<Void, Never>,
        timeout: TimeInterval
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            Task { @MainActor [weak self] in
                await captureTask.value
                self?.finish(cleanupCompleted: true)
            }
            timeoutTask = Task { @MainActor [weak self] in
                do {
                    try await ContinuousClock().sleep(for: .seconds(max(0, timeout)))
                } catch {
                    return
                }
                self?.finish(cleanupCompleted: false)
            }
        }
    }

    private func finish(cleanupCompleted: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(returning: cleanupCompleted)
    }
}
