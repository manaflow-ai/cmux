import CmuxBrowser
import WebKit

extension WKWebView {
    @MainActor
    @discardableResult
    func applyBrowserUserAgentPolicy(for url: URL?) -> Bool {
        let resolvedUserAgent = BrowserUserAgentPolicy.system.customUserAgent(for: url)
        let currentUserAgent = customUserAgent.flatMap { $0.isEmpty ? nil : $0 }
        guard currentUserAgent != resolvedUserAgent else { return false }
        customUserAgent = resolvedUserAgent
        return true
    }

    @MainActor
    func browserUserAgentPolicyRestartRequest(for request: URLRequest) -> URLRequest? {
        guard let scheme = request.url?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        guard applyBrowserUserAgentPolicy(for: request.url) else { return nil }
        var restartRequest = request
        restartRequest.setValue(nil, forHTTPHeaderField: "User-Agent")
        return restartRequest
    }

    @MainActor
    func browserUserAgentPolicyRestartRequest(
        for request: URLRequest,
        targetFrameIsMainFrame: Bool?
    ) -> URLRequest? {
        guard targetFrameIsMainFrame == true else { return nil }
        return browserUserAgentPolicyRestartRequest(for: request)
    }

    @MainActor
    func restartNavigationForBrowserUserAgentPolicyIfNeeded(
        _ navigationAction: WKNavigationAction,
        decisionHandler: (WKNavigationActionPolicy) -> Void,
        willRestart: () -> Void = {},
        startReplacement: (URLRequest) -> Void
    ) -> Bool {
        guard let restartRequest = browserUserAgentPolicyRestartRequest(
            for: navigationAction.request,
            targetFrameIsMainFrame: navigationAction.targetFrame?.isMainFrame
        ) else {
            return false
        }

        willRestart()
        decisionHandler(.cancel)
        startReplacement(restartRequest)
        return true
    }
}
