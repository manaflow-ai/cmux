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

    private let timeout: TimeInterval
    private let capture: Capture
    private var continuations: [UUID: CheckedContinuation<NSImage, any Error>] = [:]
    private var timeoutTimers: [UUID: Timer] = [:]

    init(timeout: TimeInterval = 5) {
        self.timeout = timeout
        capture = { webView, completion in
            BrowserScreenshotWebViewSnapshotter.captureVisibleViewport(
                from: webView,
                completion: completion
            )
        }
    }

    init(timeout: TimeInterval, capture: @escaping Capture) {
        self.timeout = timeout
        self.capture = capture
    }

    func captureVisibleViewport(from webView: WKWebView) async throws -> NSImage {
        let operationID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                continuations[operationID] = continuation

                // WebKit has no snapshot cancellation handle, so a one-shot main-run-loop
                // deadline and its callback race to resolve this continuation exactly once.
                let timeoutTimer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.finish(
                            operationID,
                            throwing: BrowserDesignModeSendError.operationTimedOut
                        )
                    }
                }
                timeoutTimers[operationID] = timeoutTimer
                RunLoop.main.add(timeoutTimer, forMode: .common)

                capture(webView) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let image):
                        finish(operationID, returning: image)
                    case .failure(let error):
                        finish(operationID, throwing: error)
                    }
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.finish(operationID, throwing: CancellationError())
            }
        }
    }

    func cancelAll() {
        for operationID in Array(continuations.keys) {
            finish(operationID, throwing: CancellationError())
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
        timeoutTimers.removeValue(forKey: operationID)?.invalidate()
        return continuations.removeValue(forKey: operationID)
    }
}
