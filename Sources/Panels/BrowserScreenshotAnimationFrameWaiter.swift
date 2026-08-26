import Foundation
import WebKit

/// Waits for WebKit's animation-frame callback with a cancellable common-mode deadline.
@MainActor
final class BrowserScreenshotAnimationFrameWaiter {
    typealias FrameStarter = @MainActor (
        _ script: String,
        _ completion: @escaping @MainActor (Error?) -> Void
    ) -> Void

    private let startFrame: FrameStarter
    private let timeout: TimeInterval
    private let completionGate = BrowserScreenshotContinuationGate<Void>()
    private var timeoutTimer: Timer?
    private var isCancelled = false

    init(webView: WKWebView, timeout: TimeInterval) {
        self.startFrame = { [weak webView] script, completion in
            guard let webView else {
                completion(nil)
                return
            }
            webView.callAsyncJavaScript(
                script,
                arguments: [:],
                in: nil,
                in: .defaultClient
            ) { result in
                if case .failure(let error) = result {
                    completion(error)
                } else {
                    completion(nil)
                }
            }
        }
        self.timeout = timeout
    }

    init(timeout: TimeInterval, startFrame: @escaping FrameStarter) {
        self.startFrame = startFrame
        self.timeout = timeout
    }

    func wait(script: String) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
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

        startFrame(script) { [weak self] error in
#if DEBUG
            if let error {
                cmuxDebugLog(
                    "browser.screenshot.synchronize.failed error=\(error.localizedDescription)"
                )
            }
#endif
            if let error {
                self?.finish(.failure(error))
            } else {
                self?.finish(.success(()))
            }
        }
    }

    private func cancel() {
        isCancelled = true
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Void, Error>) {
        guard completionGate.finish(result) else { return }
        timeoutTimer?.invalidate()
        timeoutTimer = nil
    }
}
