import Foundation
import WebKit

/// Owns one bounded, cancellable JavaScript evaluation against a browser web view.
@MainActor
final class BrowserScreenshotJavaScriptRequest {
    typealias EvaluationStarter = @MainActor (
        _ script: String,
        _ completion: @escaping @MainActor (Result<Any?, Error>) -> Void
    ) -> Void

    private let timeout: TimeInterval
    private let startEvaluation: EvaluationStarter
    private let completionGate = BrowserScreenshotContinuationGate<Any?>()
    private var timeoutTimer: Timer?
    private var isCancelled = false

    init(webView: WKWebView, timeout: TimeInterval) {
        self.timeout = timeout
        self.startEvaluation = { [weak webView] script, completion in
            guard let webView else {
                completion(.success(nil))
                return
            }
            webView.evaluateJavaScript(
                script,
                in: nil,
                in: .defaultClient
            ) { result in
                switch result {
                case .success(let value):
                    completion(.success(value))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    init(timeout: TimeInterval, startEvaluation: @escaping EvaluationStarter) {
        self.timeout = timeout
        self.startEvaluation = startEvaluation
    }

    func evaluate(script: String) async throws -> Any? {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard completionGate.install(continuation) else { return }
                guard !Task.isCancelled, !isCancelled else {
                    finish(.failure(CancellationError()))
                    return
                }
                start(script: script)
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    private func start(script: String) {
        let timer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finish(.failure(BrowserScreenshotError.automationTimedOut))
            }
        }
        timeoutTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        startEvaluation(script) { [weak self] result in
            self?.finish(result)
        }
    }

    private func cancel() {
        isCancelled = true
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Any?, Error>) {
        guard completionGate.finish(result) else { return }
        timeoutTimer?.invalidate()
        timeoutTimer = nil
    }
}
