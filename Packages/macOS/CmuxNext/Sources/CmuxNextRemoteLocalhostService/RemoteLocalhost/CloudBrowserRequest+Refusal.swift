extension CloudBrowserRequest {
    /// Typed validation and opening failures with stable caller-facing codes.
    public enum Refusal: Error, Equatable {
        /// A machine store opens only in Chromium (`engine: "cef"`).
        case proxyRequiresCEF
        /// The machine store or proxy is missing or not the local HTTP proxy on 127.0.0.1.
        case proxyInvalid
        /// The caller may not hand over a proxy (only the Cloud page may).
        case proxyOriginRefused
        /// Chromium is not available, or failed to make the tab.
        case cefUnavailable
        /// The URL is not an http(s) loopback URL.
        case invalidURL
        /// No window to open the tab in.
        case noWindow

        /// Stable error code returned to the page or CLI caller.
        public var code: String {
            switch self {
            case .proxyRequiresCEF: "cmux.browser.proxy_requires_cef"
            case .proxyInvalid: "cmux.browser.proxy_invalid"
            case .proxyOriginRefused: "cmux.browser.proxy_origin_refused"
            case .cefUnavailable: "cmux.browser.cef_unavailable"
            case .invalidURL: "cmux.browser.invalid_url"
            case .noWindow: "cmux.browser.no_window"
            }
        }
    }
}
