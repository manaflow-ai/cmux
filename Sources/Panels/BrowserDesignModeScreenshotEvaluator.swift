import AppKit
import Foundation
import WebKit

/// Bounds design-mode screenshot capture and releases awaiters on lifecycle cancellation.
@MainActor
final class BrowserDesignModeScreenshotEvaluator {
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
    private let visibleViewportCapture: Capture
    private let fullPageCapture: ProgressiveCapture
    private let documentRectCapture: DocumentRectCapture
    private let fullPageUsesInactivityTimeout: Bool
    private var continuations: [UUID: CheckedContinuation<NSImage, any Error>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var captureTasks: [UUID: Task<Void, Never>] = [:]

    init(timeout: TimeInterval = 5) {
        self.timeout = timeout
        visibleViewportCapture = { webView, completion in
            BrowserScreenshotWebViewSnapshotter.captureVisibleViewport(
                from: webView,
                completion: completion
            )
        }
        fullPageCapture = { webView, onProgress in
            try await BrowserScreenshotWebViewSnapshotter.captureFullPage(
                from: webView,
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

    convenience init(timeout: TimeInterval, capture: @escaping Capture) {
        self.init(
            timeout: timeout,
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
        self.visibleViewportCapture = visibleViewportCapture
        self.fullPageCapture = { webView, _ in
            try await fullPageCapture(webView)
        }
        self.documentRectCapture = documentRectCapture
        fullPageUsesInactivityTimeout = false
    }

    init(
        timeout: TimeInterval,
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
        return try await withTaskCancellationHandler {
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
                self?.finish(operationID, throwing: CancellationError())
            }
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
            self?.finish(
                operationID,
                throwing: BrowserDesignModeError.operationTimedOut
            )
        }
    }

    func cancelAll() {
        for operationID in Array(continuations.keys) {
            finish(operationID, throwing: CancellationError())
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

    private func removeOperation(
        _ operationID: UUID
    ) -> CheckedContinuation<NSImage, any Error>? {
        timeoutTasks.removeValue(forKey: operationID)?.cancel()
        captureTasks.removeValue(forKey: operationID)?.cancel()
        return continuations.removeValue(forKey: operationID)
    }
}
