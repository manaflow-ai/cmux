public import Foundation

/// A server or proxy asking a page for a user name and password (HTTP Basic,
/// Digest, NTLM or Negotiate), as reported by an engine that lets cmux
/// answer it (the Chromium engine's `GetAuthCredentials`). WebKit pages keep
/// answering through their navigation delegate.
public struct BrowserPageAuthenticationChallenge: Equatable, Hashable, Sendable {
    /// The URL whose load asked, when known.
    public var url: URL?
    /// The server (or proxy) host.
    public var host: String
    /// The server (or proxy) port.
    public var port: Int
    /// The realm the server sent, if any (untrusted text: format it with
    /// ``BrowserAuthPromptTextFormatter`` before showing it).
    public var realm: String?
    /// The authentication scheme, lowercased (`basic`, `digest`, `ntlm`, `negotiate`).
    public var scheme: String
    /// Whether a proxy asks rather than the site.
    public var isProxy: Bool

    public init(url: URL?, host: String, port: Int, realm: String?, scheme: String, isProxy: Bool) {
        self.url = url
        self.host = host
        self.port = port
        self.realm = realm
        self.scheme = scheme.lowercased()
        self.isProxy = isProxy
    }

    /// The Foundation protection space of the challenge, so the panel's
    /// existing sign-in sheet and credential keys apply to both engines.
    public var protectionSpace: URLProtectionSpace {
        let method: String = switch scheme {
        case "digest": NSURLAuthenticationMethodHTTPDigest
        case "ntlm": NSURLAuthenticationMethodNTLM
        case "negotiate": NSURLAuthenticationMethodNegotiate
        default: NSURLAuthenticationMethodHTTPBasic
        }
        let isSecure = url?.scheme?.lowercased() == "https"
        if isProxy {
            return URLProtectionSpace(
                proxyHost: host, port: port, type: isSecure ? NSURLProtectionSpaceHTTPSProxy : NSURLProtectionSpaceHTTPProxy,
                realm: realm, authenticationMethod: method
            )
        }
        return URLProtectionSpace(
            host: host, port: port, protocol: isSecure ? NSURLProtectionSpaceHTTPS : NSURLProtectionSpaceHTTP,
            realm: realm, authenticationMethod: method
        )
    }
}

/// The answer to a ``BrowserPageAuthenticationChallenge``.
public enum BrowserPageAuthenticationResponse: Equatable, Sendable {
    /// Sign in with these credentials.
    case credential(user: String, password: String)
    /// Cancel: the page shows the server's 401/407 response.
    case cancel
}

/// Implemented by a page's UI delegate (the browser panel) to answer sign-in
/// challenges from engines that report them. An engine whose delegate does
/// not conform cancels the challenge.
@MainActor
public protocol BrowserPageAuthenticationDelegate: AnyObject {
    /// Asks the person (or a saved credential) for a sign-in.
    /// - Parameters:
    ///   - page: The page whose load asked.
    ///   - challenge: The challenge.
    /// - Returns: Credentials, or cancel.
    func page(_ page: any BrowserPage, didReceive challenge: BrowserPageAuthenticationChallenge) async -> BrowserPageAuthenticationResponse
}
