public import ObjectiveC
public import WebKit

extension WKWebView {
    /// Applies the destination identity and reports whether an HTTP(S) navigation must restart.
    @MainActor
    @discardableResult
    public func applyBrowserUserAgentPolicy(for url: URL?) -> Bool {
        // WebKit exposes its native identity as either nil or an empty string across load phases.
        let currentUserAgent = customUserAgent.flatMap { $0.isEmpty ? nil : $0 }
        let resolvedUserAgent: String?
        if let override = automationUserAgentOverride {
            resolvedUserAgent = override
        } else {
            switch BrowserUserAgentPolicy.system.resolution(for: url) {
            case .custom(let userAgent):
                resolvedUserAgent = userAgent
            case .notApplicable:
                guard currentUserAgent != nil else { return false }
                customUserAgent = nil
                return false
            }
        }

        guard currentUserAgent != resolvedUserAgent else { return false }
        customUserAgent = resolvedUserAgent
        return true
    }

    @MainActor
    public func browserUserAgentPolicyRestartRequest(for request: URLRequest) -> URLRequest? {
        browserUserAgentPolicyRestartRequest(for: request, addsAutomationHeaders: false)
    }

    /// The request to restart a main-frame navigation with when the user agent
    /// changes or, with `addsAutomationHeaders`, when the request lacks one of
    /// `automationExtraHTTPHeaders` (only a GET without a body is restarted,
    /// so no form data is replayed).
    @MainActor
    public func browserUserAgentPolicyRestartRequest(
        for request: URLRequest,
        addsAutomationHeaders: Bool
    ) -> URLRequest? {
        let userAgentChanged = applyBrowserUserAgentPolicy(for: request.url)
        let missingHeaders = addsAutomationHeaders ? automationHeadersMissing(from: request) : [:]
        guard userAgentChanged || !missingHeaders.isEmpty else { return nil }
        var restartRequest = request
        if userAgentChanged {
            restartRequest.setValue(nil, forHTTPHeaderField: "User-Agent")
        }
        for (name, value) in missingHeaders {
            restartRequest.setValue(value, forHTTPHeaderField: name)
        }
        return restartRequest
    }

    /// Headers from `automationExtraHTTPHeaders` that `request` does not carry
    /// with the same value, for an HTTP(S) GET without a body.
    @MainActor
    public func automationHeadersMissing(from request: URLRequest) -> [String: String] {
        let headers = automationExtraHTTPHeaders
        guard !headers.isEmpty,
              let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https",
              (request.httpMethod ?? "GET").uppercased() == "GET",
              request.httpBody == nil, request.httpBodyStream == nil else { return [:] }
        return headers.filter { request.value(forHTTPHeaderField: $0.key) != $0.value }
    }

    /// A user agent automation set for this web view (the browser REPL's
    /// `session.configure({ userAgent })`). It wins over the destination
    /// policy until cleared.
    @MainActor
    public var automationUserAgentOverride: String? {
        get { objc_getAssociatedObject(self, BrowserAutomationIdentityKeys.userAgent) as? String }
        set {
            objc_setAssociatedObject(self, BrowserAutomationIdentityKeys.userAgent, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC)
            applyBrowserUserAgentPolicy(for: url)
        }
    }

    /// Headers automation adds to this web view's main-frame navigations (the
    /// browser REPL's `session.configure({ extraHTTPHeaders })`).
    @MainActor
    public var automationExtraHTTPHeaders: [String: String] {
        get { objc_getAssociatedObject(self, BrowserAutomationIdentityKeys.headers) as? [String: String] ?? [:] }
        set {
            objc_setAssociatedObject(
                self,
                BrowserAutomationIdentityKeys.headers,
                newValue.isEmpty ? nil : newValue as NSDictionary,
                .OBJC_ASSOCIATION_COPY_NONATOMIC
            )
        }
    }

    @MainActor
    public func browserUserAgentPolicyRestartRequest(
        for request: URLRequest,
        targetFrameIsMainFrame: Bool?,
        addsAutomationHeaders: Bool = false
    ) -> URLRequest? {
        guard targetFrameIsMainFrame == true else { return nil }
        return browserUserAgentPolicyRestartRequest(for: request, addsAutomationHeaders: addsAutomationHeaders)
    }

    /// Applies a changed user-agent policy to a main-frame request and starts its replacement.
    @MainActor
    @discardableResult
    public func restartNavigationForBrowserUserAgentPolicyIfNeeded(
        request: URLRequest,
        targetFrameIsMainFrame: Bool?,
        addsAutomationHeaders: Bool = false,
        decisionHandler: (WKNavigationActionPolicy) -> Void,
        willRestart: () -> Void = {},
        startReplacement: (URLRequest) -> Void
    ) -> Bool {
        guard let restartRequest = browserUserAgentPolicyRestartRequest(
            for: request,
            targetFrameIsMainFrame: targetFrameIsMainFrame,
            addsAutomationHeaders: addsAutomationHeaders
        ) else {
            return false
        }

        willRestart()
        decisionHandler(.cancel)
        startReplacement(restartRequest)
        return true
    }
}

private enum BrowserAutomationIdentityKeys {
    nonisolated(unsafe) static let userAgent = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))
    nonisolated(unsafe) static let headers = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))
}
