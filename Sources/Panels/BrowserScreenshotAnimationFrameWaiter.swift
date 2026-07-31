import Foundation
import WebKit

/// Waits for WebKit's animation-frame callback with a cancellable common-mode deadline.
@MainActor
final class BrowserScreenshotAnimationFrameWaiter {
    private weak var webView: WKWebView?
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<Void, Never>?
    private var timeoutTimer: Timer?
    private var isCancelled = false
    private var didFinish = false

    init(webView: WKWebView, timeout: TimeInterval) {
        self.webView = webView
        self.timeout = timeout
    }

    func wait(script: String) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled, !isCancelled else {
                    finish()
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
        guard let webView else {
            finish()
            return
        }

        let timer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finish()
            }
        }
        timeoutTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        webView.callAsyncJavaScript(
            script,
            arguments: [:],
            in: nil,
            in: .defaultClient
        ) { [weak self] result in
            _ = result
#if DEBUG
            let errorDescription: String?
            if case .failure(let error) = result {
                errorDescription = error.localizedDescription
            } else {
                errorDescription = nil
            }
#endif
            Task { @MainActor [weak self] in
#if DEBUG
                if let errorDescription {
                    cmuxDebugLog(
                        "browser.screenshot.synchronize.failed error=\(errorDescription)"
                    )
                }
#endif
                self?.finish()
            }
        }
    }

    private func cancel() {
        isCancelled = true
        finish()
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        continuation?.resume()
        continuation = nil
    }
}
