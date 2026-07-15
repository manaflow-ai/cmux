import Foundation
import WebKit

/// Bounds design-mode JavaScript calls and releases awaiters on lifecycle cancellation.
@MainActor
final class BrowserDesignModeJavaScriptEvaluator {
    private let timeout: TimeInterval
    private var continuations: [UUID: CheckedContinuation<Any?, any Error>] = [:]
    private var timeoutTimers: [UUID: Timer] = [:]

    init(timeout: TimeInterval = 5) {
        self.timeout = timeout
    }

    func call(
        _ body: String,
        arguments: [String: Any],
        in webView: WKWebView,
        contentWorld: WKContentWorld
    ) async throws -> Any? {
        let operationID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                continuations[operationID] = continuation

                // Genuine one-shot operation deadline. WebKit exposes no cancellation
                // handle, so its callback and this main-run-loop timer race to resolve
                // the continuation; the winner invalidates the timer.
                let timeoutTimer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.finish(
                            operationID,
                            throwing: BrowserDesignModeError.operationTimedOut
                        )
                    }
                }
                timeoutTimers[operationID] = timeoutTimer
                RunLoop.main.add(timeoutTimer, forMode: .common)

                webView.callAsyncJavaScript(
                    body,
                    arguments: arguments,
                    in: nil,
                    in: contentWorld
                ) { [weak self] result in
                    Task { @MainActor [weak self] in
                        switch result {
                        case .success(let value):
                            self?.finish(operationID, returning: value)
                        case .failure(let error):
                            self?.finish(operationID, throwing: error)
                        }
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

    private func finish(_ operationID: UUID, returning value: Any?) {
        guard let continuation = removeOperation(operationID) else { return }
        continuation.resume(returning: value)
    }

    private func finish(_ operationID: UUID, throwing error: any Error) {
        guard let continuation = removeOperation(operationID) else { return }
        continuation.resume(throwing: error)
    }

    private func removeOperation(
        _ operationID: UUID
    ) -> CheckedContinuation<Any?, any Error>? {
        timeoutTimers.removeValue(forKey: operationID)?.invalidate()
        return continuations.removeValue(forKey: operationID)
    }
}
