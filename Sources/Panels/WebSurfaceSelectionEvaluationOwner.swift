import WebKit

/// Owns at most one in-flight WebKit selection evaluation for a panel.
@MainActor
final class WebSurfaceSelectionEvaluationOwner {
    private var activeID: UUID?
    private var activeContinuation: CheckedContinuation<String?, Never>?

    /// Starts a page-world evaluation, cancelling and completing any older one.
    ///
    /// WebKit does not expose a cancellable evaluation handle. Keeping the
    /// continuation and request identity here lets socket cancellation resume
    /// the caller immediately while ignoring a late WebKit callback; the
    /// in-page Promise timeout bounds a responsive WebContent process and the
    /// single active continuation prevents request fan-out when it is wedged.
    func evaluate(webView: WKWebView, script: String) async -> String? {
        finishActive(with: nil)
        let requestID = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                activeID = requestID
                activeContinuation = continuation
                webView.callAsyncJavaScript(
                    script,
                    arguments: [:],
                    in: nil,
                    in: .page
                ) { [weak self] result in
                    let value: String?
                    switch result {
                    case .success(let raw):
                        value = raw as? String
                    case .failure:
                        value = nil
                    }
                    Task { @MainActor in
                        self?.finish(requestID: requestID, value: value)
                    }
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(requestID: requestID, value: nil)
            }
        })
    }

    private func finish(requestID: UUID, value: String?) {
        guard activeID == requestID else { return }
        activeID = nil
        let continuation = activeContinuation
        activeContinuation = nil
        continuation?.resume(returning: value)
    }

    private func finishActive(with value: String?) {
        guard let activeID else { return }
        finish(requestID: activeID, value: value)
    }
}
