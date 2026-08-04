import CmuxBrowser
import ObjectiveC
import WebKit

private var cmuxBrowserUserAgentPolicyRestartedURLKey: UInt8 = 0

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

    /// Destination of the most recent user-agent-policy restart. Each
    /// destination may restart at most once in a row: when the replacement
    /// load still reports a mismatched identity, the comparison cannot
    /// converge on this system and the load must proceed instead of
    /// cancel/reload looping on the main thread (issue #9462).
    @MainActor
    private var browserUserAgentPolicyRestartedURL: URL? {
        get {
            objc_getAssociatedObject(self, &cmuxBrowserUserAgentPolicyRestartedURLKey) as? URL
        }
        set {
            objc_setAssociatedObject(
                self,
                &cmuxBrowserUserAgentPolicyRestartedURLKey,
                newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    @MainActor
    func restartNavigationForBrowserUserAgentPolicyIfNeeded(
        for request: URLRequest,
        targetFrameIsMainFrame: Bool?,
        decisionHandler: (WKNavigationActionPolicy) -> Void,
        willRestart: () -> Void = {},
        startReplacement: (URLRequest) -> Void
    ) -> Bool {
        if targetFrameIsMainFrame == true, let url = request.url {
            let alreadyRestartedForDestination = browserUserAgentPolicyRestartedURL == url
            browserUserAgentPolicyRestartedURL = nil
            if alreadyRestartedForDestination { return false }
        }
        guard let restartRequest = browserUserAgentPolicyRestartRequest(
            for: request,
            targetFrameIsMainFrame: targetFrameIsMainFrame
        ) else {
            return false
        }

        browserUserAgentPolicyRestartedURL = request.url
        willRestart()
        decisionHandler(.cancel)
        startReplacement(restartRequest)
        return true
    }
}
