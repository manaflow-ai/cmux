import CmuxBrowser
import WebKit

extension WKWebView {
    @MainActor
    @discardableResult
    func applyBrowserUserAgentPolicy(for url: URL?) -> Bool {
        let resolvedUserAgent = BrowserUserAgentPolicy.system.customUserAgent(for: url)
        guard customUserAgent != resolvedUserAgent else { return false }
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
}
