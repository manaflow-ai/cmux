#if os(iOS)
import CmuxAuthRuntime
import Foundation

/// Exchanges the native Stack session for cmux web session cookies through
/// `POST /handler/app-session-handoff`, the same exchange the macOS browser
/// performs (`BrowserAppSessionHandoff` in CmuxBrowser). The exchange runs
/// out-of-band in an ephemeral, cookie-less URLSession that refuses
/// redirects, so native tokens can only ever reach the destination's own
/// allowlisted origin, and the response is accepted only when it is the
/// expected `204` cookie exchange carrying the complete Stack cookie pair
/// scoped to that origin's host. The returned cookies are meant for a
/// non-persistent per-webview data store, so the web session dies with the
/// view that requested it.
public final class MobileWebAppSessionBroker: MobileWebAppSessionProviding, Sendable {
    private static let handoffPath = "/handler/app-session-handoff"

    private let tokens: any TokenProviding
    private let projectID: String
    private let allowedHosts: Set<String>
    private let session: URLSession

    /// Creates a broker for the app's own web allowlist (the cmux-owned
    /// production hosts plus this build's configured API host).
    public init(
        tokens: any TokenProviding,
        apiBaseURL: String?,
        projectID: String
    ) {
        self.tokens = tokens
        self.projectID = projectID
        allowedHosts = MobileWebPageHosts.allowedHosts(apiBaseURL: apiBaseURL)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(
            configuration: configuration,
            delegate: MobileWebAppSessionRedirectRejectingDelegate(),
            delegateQueue: nil
        )
    }

    public func sessionCookies(for destination: URL) async -> [HTTPCookie]? {
        guard let request = handoffRequest(for: destination) else { return nil }
        guard let snapshot = try? await tokens.authenticatedSessionSnapshot() else {
            return nil
        }
        guard let exchange = authenticated(
            request,
            destination: destination,
            tokens: snapshot
        ) else { return nil }

        guard let (_, response) = try? await session.data(for: exchange),
              let http = response as? HTTPURLResponse else {
            return nil
        }
        // The session that asked must still be the session that answers: a
        // sign-out or account switch during the exchange voids the cookies.
        guard await tokens.isAuthenticatedSessionCurrent(snapshot) else { return nil }
        return sessionCookies(from: http, destination: destination)
    }

    /// The exchange endpoint on the destination's own origin, or `nil` when
    /// the destination is off the allowlist (credentials never leave it).
    private func handoffRequest(for destination: URL) -> URLRequest? {
        guard mobileWebPageURLAllowed(destination, allowedHosts: allowedHosts),
              destination.path != Self.handoffPath,
              var components = URLComponents(
                  url: destination,
                  resolvingAgainstBaseURL: true
              ) else {
            return nil
        }
        components.path = Self.handoffPath
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        guard let handoffURL = components.url else { return nil }

        var request = URLRequest(url: handoffURL)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("1", forHTTPHeaderField: "X-Cmux-App-Session-Handoff")
        request.setValue("cookies", forHTTPHeaderField: "X-Cmux-App-Session-Response")
        return request
    }

    private func authenticated(
        _ request: URLRequest,
        destination: URL,
        tokens snapshot: AuthenticatedSessionSnapshot
    ) -> URLRequest? {
        guard !snapshot.accessToken.isEmpty,
              !snapshot.refreshToken.isEmpty else {
            return nil
        }
        let pairs: [(String, String)] = [
            ("access_token", snapshot.accessToken),
            ("refresh_token", snapshot.refreshToken),
            ("after", Self.relativePath(destination)),
        ]
        let body = pairs
            .map { "\($0.0)=\(Self.formURLEncode($0.1))" }
            .joined(separator: "&")
        var request = request
        request.httpBody = body.data(using: .utf8)
        return request
    }

    /// Extracts the complete Stack cookie pair from a native exchange
    /// response. Returning `nil` fails the handoff closed when the server, a
    /// proxy, or an authentication failure returns anything except the
    /// expected response, and drops any cookie not scoped to the
    /// destination's own host.
    private func sessionCookies(
        from response: HTTPURLResponse,
        destination: URL
    ) -> [HTTPCookie]? {
        guard response.statusCode == 204,
              response.value(forHTTPHeaderField: "X-Cmux-App-Session-Handoff") == "ready",
              let responseURL = response.url,
              Self.sameOrigin(responseURL, destination) else {
            return nil
        }
        guard let setCookie = response.value(forHTTPHeaderField: "Set-Cookie") else {
            return nil
        }
        let host = destination.host?.lowercased() ?? ""
        let cookies = HTTPCookie.cookies(
            withResponseHeaderFields: ["Set-Cookie": setCookie],
            for: responseURL
        ).filter { cookie in
            isStackCookie(cookie.name)
                && cookie.domain
                    .lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".")) == host
        }
        let names = Set(cookies.map(\.name))
        let accessNames = ["stack-access", "hexclave-access"]
        let refreshNames = [
            "stack-refresh-\(projectID)",
            "hexclave-refresh-\(projectID)",
        ]
        let prefixes = ["", "__Host-", "__Secure-"]
        let hasAccess = prefixes.contains { prefix in
            accessNames.contains { names.contains("\(prefix)\($0)") }
        }
        let hasRefresh = prefixes.contains { prefix in
            refreshNames.contains { base in
                names.contains("\(prefix)\(base)")
                    || names.contains { $0.hasPrefix("\(prefix)\(base)--") }
            }
        }
        return hasAccess && hasRefresh ? cookies : nil
    }

    private func isStackCookie(_ name: String) -> Bool {
        let prefixes = ["", "__Host-", "__Secure-"]
        let exactNames = [
            "stack-access",
            "hexclave-access",
            "stack-refresh",
            "hexclave-refresh",
        ]
        let scopedRefreshNames = [
            "stack-refresh-\(projectID)",
            "hexclave-refresh-\(projectID)",
        ]
        return prefixes.contains { prefix in
            exactNames.contains { name == "\(prefix)\($0)" }
                || scopedRefreshNames.contains {
                    name == "\(prefix)\($0)" || name.hasPrefix("\(prefix)\($0)--")
                }
        }
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private static func formURLEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func relativePath(_ url: URL) -> String {
        var result = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            result += "?\(query)"
        }
        if let fragment = url.fragment, !fragment.isEmpty {
            result += "#\(fragment)"
        }
        return result
    }
}

/// Prevents the handoff exchange from following server redirects, so the
/// token-bearing POST can never be replayed against another host.
///
/// Safety: `URLSession` may call this stateless delegate concurrently. It
/// owns no mutable state and completes each callback using only the callback
/// inputs.
private final class MobileWebAppSessionRedirectRejectingDelegate:
    NSObject,
    URLSessionTaskDelegate,
    // Safety: this delegate is stateless and each callback is self-contained.
    @unchecked Sendable
{
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
#endif
