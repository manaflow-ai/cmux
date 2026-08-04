import CmuxBrowser
import WebKit

extension WKWebView {
    /// Applies the destination identity and reports whether an HTTP(S) navigation must restart.
    @MainActor
    @discardableResult
    func applyBrowserUserAgentPolicy(for url: URL?) -> Bool {
        applyBrowserUserAgentPolicy(BrowserUserAgentPolicy.system.resolution(for: url))
    }

    @MainActor
    private func applyBrowserUserAgentPolicy(
        _ resolution: BrowserUserAgentPolicyResolution
    ) -> Bool {
        // WebKit exposes its native identity as either nil or an empty string across load phases.
        let currentUserAgent = customUserAgent.flatMap { $0.isEmpty ? nil : $0 }
        let resolvedUserAgent: String?
        switch resolution {
        case .custom(let userAgent):
            resolvedUserAgent = userAgent
        case .webKitDefault:
            resolvedUserAgent = nil
        case .notApplicable:
            guard currentUserAgent != nil else { return false }
            customUserAgent = nil
            return false
        }

        guard currentUserAgent != resolvedUserAgent else { return false }
        customUserAgent = resolvedUserAgent
        return true
    }

    /// Applies the WebKit identity and prepares the top-level request identity.
    @MainActor
    func browserUserAgentPolicyPreparedRequest(for request: URLRequest) -> URLRequest {
        let resolution = BrowserUserAgentPolicy.system.resolution(for: request.url)
        _ = applyBrowserUserAgentPolicy(resolution)

        var preparedRequest = request
        switch resolution {
        case .custom:
            preparedRequest.setValue(nil, forHTTPHeaderField: "User-Agent")
        case .webKitDefault(let topLevelRequestUserAgent):
            preparedRequest.setValue(topLevelRequestUserAgent, forHTTPHeaderField: "User-Agent")
        case .notApplicable:
            break
        }
        return preparedRequest
    }

    @MainActor
    func browserUserAgentPolicyRestartRequest(for request: URLRequest) -> URLRequest? {
        let resolution = BrowserUserAgentPolicy.system.resolution(for: request.url)
        let identityChanged = applyBrowserUserAgentPolicy(resolution)

        switch resolution {
        case .custom:
            guard identityChanged else { return nil }
            var restartRequest = request
            restartRequest.setValue(nil, forHTTPHeaderField: "User-Agent")
            return restartRequest
        case .webKitDefault(let topLevelRequestUserAgent):
            let requestIdentityChanged = request.value(forHTTPHeaderField: "User-Agent")
                != topLevelRequestUserAgent
            guard identityChanged || requestIdentityChanged else { return nil }
            var restartRequest = request
            restartRequest.setValue(topLevelRequestUserAgent, forHTTPHeaderField: "User-Agent")
            return restartRequest
        case .notApplicable:
            return nil
        }
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
