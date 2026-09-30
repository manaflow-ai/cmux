public import Foundation

/// How a page's connection is presented (Chromium `security_state`
/// levels as Page Info words them).
public nonisolated enum PageInfoConnection: Hashable, Sendable {
    /// HTTPS, valid certificate: "Connection is secure".
    case secure
    /// Plain HTTP: "Connection is not secure".
    case insecure
    /// HTTPS with insecure subresources: "Connection is not fully secure".
    case mixedContent
    /// HTTPS whose certificate failed verification. `code` is the engine's
    /// error code when the load failed on it.
    case certificateError(code: Int?)
    /// Flagged as malware or phishing: "Dangerous site".
    case dangerous
}

/// What kind of page the omnibar shows. Chrome's page info differs per kind:
/// web pages get the connection row, permissions and cookies; local files,
/// internal and extension pages get a single identity line.
public nonisolated enum PageInfoSiteKind: Hashable, Sendable {
    case web(PageInfoConnection)
    /// `file:` URLs: "You're viewing a local or shared file".
    case file
    /// cmux internal pages (`cmux:`, `about:` other than blank, `chrome:`).
    case internalPage
    /// `chrome-extension:` pages.
    case extensionPage
    /// `view-source:` pages.
    case viewSource
    /// `devtools:` pages.
    case devTools
    /// No page, or `about:blank`: nothing to show.
    case empty
}

/// The site a page info bubble describes, derived from the tab state alone.
public nonisolated struct PageInfoSite: Hashable, Sendable {
    public var url: URL?
    public var kind: PageInfoSiteKind

    public init(url: URL?, kind: PageInfoSiteKind) {
        self.url = url
        self.kind = kind
    }

    /// Classifies a tab. A load that failed on a certificate error shows the
    /// failing URL with a broken connection, as Chrome's interstitial does.
    public init(state: BrowserTabState) {
        if let error = state.loadError, Self.isCertificateError(error) {
            self.init(url: error.failingURL ?? state.url, kind: .web(.certificateError(code: error.code)))
            return
        }
        self.init(url: state.url, security: state.security)
    }

    /// The security the omnibar shows: the tab's, or `.broken` while a
    /// certificate error page is up.
    public static func omnibarSecurity(for state: BrowserTabState) -> BrowserSecurityState {
        if let error = state.loadError, isCertificateError(error) { return .broken }
        return state.security
    }

    public init(url: URL?, security: BrowserSecurityState) {
        self.url = url
        guard let url, let scheme = url.scheme?.lowercased() else {
            kind = .empty
            return
        }
        switch scheme {
        case "https", "http":
            kind = .web(Self.connection(scheme: scheme, security: security))
        case "file":
            kind = .file
        case "about":
            kind = url.absoluteString.lowercased().hasPrefix("about:blank") ? .empty : .internalPage
        case "cmux", "chrome", "cef":
            kind = .internalPage
        case "chrome-extension":
            kind = .extensionPage
        case "view-source":
            kind = .viewSource
        case "devtools":
            kind = .devTools
        default:
            // data:, blob: and unknown schemes have no identity to show.
            kind = .empty
        }
    }

    private static func connection(scheme: String, security: BrowserSecurityState) -> PageInfoConnection {
        switch security {
        case .dangerous: return .dangerous
        case .broken: return .certificateError(code: nil)
        case .mixedContent: return .mixedContent
        case .insecure: return .insecure
        case .secure: return scheme == "https" ? .secure : .insecure
        case .none, .local: return scheme == "https" ? .secure : .insecure
        }
    }

    /// True for web pages: the bubble has permissions, cookies, and site settings.
    public var isWeb: Bool {
        if case .web = kind { return true }
        return false
    }

    public var connection: PageInfoConnection? {
        if case .web(let connection) = kind { return connection }
        return nil
    }

    /// `scheme://host[:port]`, the key for permission decisions and site data.
    public var origin: String? {
        guard isWeb, let url else { return nil }
        return Self.origin(of: url)
    }

    public var host: String? { url?.host(percentEncoded: false)?.lowercased() }

    /// The bubble title: the URL formatted for security display with the
    /// scheme omitted for http(s) (Chromium `FormatUrlForSecurityDisplay`,
    /// `OMIT_HTTP_AND_HTTPS`); local files show their path.
    public var displayName: String {
        guard let url else { return "" }
        switch kind {
        case .web:
            guard let host = url.host(percentEncoded: false) else { return url.absoluteString }
            let port = url.port.map { Self.isDefault(port: $0, scheme: url.scheme) ? "" : ":\($0)" } ?? ""
            return host + port
        case .file:
            return url.path(percentEncoded: false)
        case .internalPage, .extensionPage, .viewSource, .devTools, .empty:
            guard let scheme = url.scheme, let host = url.host(percentEncoded: false) else { return url.absoluteString }
            return "\(scheme)://\(host)"
        }
    }

    public static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        let port = url.port.map { isDefault(port: $0, scheme: scheme) ? "" : ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private static func isDefault(port: Int, scheme: String?) -> Bool {
        (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
    }

    /// WebKit `NSURLErrorServerCertificate*` / secure connection failures,
    /// and Chromium net errors -200...-299 (the certificate error range).
    public static func isCertificateError(_ error: BrowserLoadError) -> Bool {
        switch error.domain {
        case NSURLErrorDomain:
            return (-1206 ... -1200).contains(error.code)
        case "net":
            return (-299 ... -200).contains(error.code)
        default:
            return false
        }
    }
}
