import AppKit
import Foundation
import WebKit

/// An ephemeral WebKit host with no native handlers or persisted website data (Lucas 2026-10-19).
@MainActor
final class AgentPaneRenderPreview: NSObject, WKNavigationDelegate, WKURLSchemeHandler {
    private var view: WKWebView?
    private var continuation: CheckedContinuation<String, any Error>?
    private var deadline: Task<Void, Never>?
    private var evaluating = false
    private var releasePanel: (@MainActor () -> Void)?

    /// The report as JSON, so nothing non-Sendable crosses the continuation.
    func capture(document: String, width: Int, dark: Bool, dataStore: WKWebsiteDataStore,
                 park: @MainActor (WKWebView) -> (@MainActor () -> Void)) async throws -> String {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.setURLSchemeHandler(self, forURLScheme: AgentPaneSource.bundledScheme)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: CGFloat(width), height: 1600), configuration: configuration)
        self.view = view
        view.navigationDelegate = self
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        releasePanel = park(view)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.deadline = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    self?.finish(.failure(AgentPaneRenderPreviewError.timeout))
                }
                view.loadHTMLString(document, baseURL: nil)
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !evaluating, continuation != nil else { return }
        evaluating = true
        webView.callAsyncJavaScript("return await window.cmuxPreviewResult", arguments: [:], in: nil, in: .page) { [weak self, weak webView] (result: Result<Any, any Error>) in
            guard let self, let webView, self.continuation != nil else { return }
            switch result {
            case .failure(let error): self.finish(.failure(error))
            case .success(let raw):
                if let report = raw as? [String: Any], let code = report["error"] as? String {
                    self.finish(.failure(AgentPaneRenderPreviewError(rawValue: code) ?? .failed))
                    return
                }
                guard let report = raw as? [String: Any], let height = report["capturedHeight"] as? Double,
                      height.isFinite, height >= 1, height <= 1600 else {
                    self.finish(.failure(AgentPaneRenderPreviewError.notLaidOut))
                    return
                }
                let snapshot = WKSnapshotConfiguration()
                snapshot.rect = NSRect(x: 0, y: 0, width: webView.bounds.width, height: CGFloat(height))
                snapshot.snapshotWidth = NSNumber(value: Double(webView.bounds.width))
                webView.takeSnapshot(with: snapshot) { [weak self, weak webView] image, error in
                    guard let self, let webView, self.continuation != nil else { return }
                    guard let image = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                          let reportData = try? JSONSerialization.data(withJSONObject: report) else {
                        self.finish(.failure(error ?? AgentPaneRenderPreviewError.failed))
                        return
                    }
                    let width = Int(webView.bounds.width)
                    Task { @MainActor [weak self] in
                        let result = await Task.detached(priority: .userInitiated) {
                            Result { try AgentPaneRenderPreviewPNG().encode(image, width: width, height: Int(height), report: reportData) }
                        }.value
                        self?.finish(result)
                    }
                }
            }
        }
    }

    @objc(webView:decidePolicyForNavigationAction:decisionHandler:)
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Only the initial documents may load. A frame cannot navigate after its bootstrap.
        let initial = action.navigationType == .other && action.sourceFrame.isMainFrame
        let allowed = initial && Self.allowsInitialDocument(action.request.url, mainFrame: action.targetFrame?.isMainFrame == true)
        decisionHandler(allowed ? .allow : .cancel)
    }

    static func allowsInitialDocument(_ url: URL?, mainFrame: Bool) -> Bool {
        mainFrame ? url?.absoluteString == "about:blank" : url.map(AgentPaneRenderFrame.isFrame) == true
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(URLError(.cannotLoadFromNetwork)))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard task.request.httpMethod == "GET", let url = task.request.url, AgentPaneRenderFrame.isFrame(url),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: AgentPaneRenderFrame.headers(length: AgentPaneRenderFrame.document.count)) else {
            task.didFailWithError(URLError(.unsupportedURL))
            return
        }
        task.didReceive(response)
        task.didReceive(AgentPaneRenderFrame.document)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func finish(_ result: Result<String, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel()
        deadline = nil
        view?.stopLoading()
        view?.navigationDelegate = nil
        releasePanel?()
        releasePanel = nil
        view = nil
        continuation.resume(with: result)
    }
}
