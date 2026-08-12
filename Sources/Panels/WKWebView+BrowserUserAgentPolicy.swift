import CmuxBrowser
import WebKit

extension WKWebView {
    /// Applies the destination identity and reports whether an HTTP(S) navigation must restart.
    @MainActor
    @discardableResult
    func applyBrowserUserAgentPolicy(for url: URL?) -> Bool {
        // WebKit exposes its native identity as either nil or an empty string across load phases.
        let currentUserAgent = customUserAgent.flatMap { $0.isEmpty ? nil : $0 }
        let resolvedUserAgent: String?
        switch BrowserUserAgentPolicy.system.resolution(for: url) {
        case .custom(let userAgent):
            resolvedUserAgent = userAgent
        case .notApplicable:
            guard currentUserAgent != nil else { return false }
            customUserAgent = nil
            return false
        }

        guard currentUserAgent != resolvedUserAgent else { return false }
        customUserAgent = resolvedUserAgent
        return true
    }

    @MainActor
    func browserUserAgentPolicyRestartRequest(for request: URLRequest) -> URLRequest? {
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
