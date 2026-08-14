import CmuxAuthRuntime
import Foundation

/// The short-lived, one-use authority that cmux passes to CodeRouter.
///
/// The value is intentionally kept in a small Sendable DTO. Callers must not
/// log or persist it. The control-socket response is the only supported
/// transport out of cmux.
struct CodeRouterHandoffLease: Sendable, Equatable {
    let teamID: String
    let lease: String
    let expiresAt: String
}

/// The auth surface needed by the hosted handoff client.
///
/// Keeping this surface narrow makes account, sign-out, and team changes
/// testable without constructing the full AppKit auth graph. AuthCoordinator
/// is the production conformer below.
protocol CodeRouterHandoffAuthProviding: Sendable {
    func authenticatedSessionSnapshot() async throws -> AuthenticatedSessionSnapshot
    func isAuthenticatedSessionCurrent(_ snapshot: AuthenticatedSessionSnapshot) async -> Bool
    func codeRouterHandoffResolvedTeamID() async -> String?
}

extension AuthCoordinator: CodeRouterHandoffAuthProviding {
    public func codeRouterHandoffResolvedTeamID() async -> String? {
        resolvedTeamID
    }
}

/// Errors returned by the native hosted handoff path.
///
/// Descriptions are fixed and never include a URL, response body, Stack token,
/// or lease. This is important because socket errors can be copied into shell
/// output and diagnostic logs.
enum CodeRouterHandoffClientError: Error, Equatable, Sendable, CustomStringConvertible {
    case notSignedIn
    case sessionUnavailable
    case sessionChanged
    case invalidTeam
    case invalidResponse
    case expiredLease
    case redirectedResponse
    case httpStatus(Int)
    case backendUnreachable

    var code: String {
        switch self {
        case .notSignedIn:
            return "coderouter_handoff_not_authenticated"
        case .sessionUnavailable, .backendUnreachable:
            return "coderouter_handoff_unavailable"
        case .sessionChanged:
            return "coderouter_handoff_session_changed"
        case .invalidTeam:
            return "coderouter_handoff_invalid_team"
        case .invalidResponse, .redirectedResponse:
            return "coderouter_handoff_invalid_response"
        case .expiredLease:
            return "coderouter_handoff_expired"
        case .httpStatus:
            return "coderouter_handoff_http_error"
        }
    }

    var description: String {
        switch self {
        case .notSignedIn:
            return "CodeRouter handoff requires a signed-in cmux account."
        case .sessionUnavailable, .backendUnreachable:
            return "The cmux service is not available. Check your connection and try again."
        case .sessionChanged:
            return "The cmux account or team changed during the handoff. Try again."
        case .invalidTeam:
            return "The selected cmux team is invalid."
        case .invalidResponse, .redirectedResponse:
            return "The cmux service returned an invalid handoff response."
        case .expiredLease:
            return "The cmux handoff lease is expired. Try again."
        case .httpStatus:
            return "The cmux service rejected the CodeRouter handoff."
        }
    }
}

/// Mints a hosted CodeRouter handoff lease with the native Stack session.
///
/// This actor owns an ephemeral, cookie-free URLSession. It sends the
/// coherent Stack access/refresh pair only to the configured cmux VM API
/// origin, and it refuses to return a lease if the account or selected team
/// changes while the request is in flight.
actor CodeRouterHandoffClient {
    private static let hostedOrigin = URL(string: "https://coderouter.dev")!
    /// Maximum time for the hosted mint HTTP request. The socket worker and
    /// CLI layers use longer bounded deadlines around this value.
    nonisolated static let httpTimeoutSeconds: TimeInterval = 18
    /// The mint response contains three short strings. Keep malformed or
    /// proxy-generated bodies from being copied into a socket-worker result.
    private static let maximumResponseBytes = 16 * 1024

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            // The handoff endpoint must never redirect a credential-bearing
            // request. Returning nil also prevents URLSession from forwarding
            // Stack headers to another origin.
            completionHandler(nil)
        }
    }

    private let requestHandler: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let auth: any CodeRouterHandoffAuthProviding
    private let baseURL: URL?
    private let clock: @Sendable () -> Date
    private let redirectDelegate: NoRedirectDelegate?

    init(
        auth: any CodeRouterHandoffAuthProviding,
        session: URLSession? = nil,
        baseURL: URL? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        requestHandler: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) {
        self.auth = auth
        let configuredBaseURL = baseURL ?? Self.defaultBaseURL
        self.baseURL = Self.allowedBaseURL(configuredBaseURL)
        self.clock = clock
        if let requestHandler {
            self.requestHandler = requestHandler
            self.redirectDelegate = nil
        } else {
            let delegate = NoRedirectDelegate()
            self.redirectDelegate = delegate
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = Self.httpTimeoutSeconds
            let configuredSession = session
                ?? URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            self.requestHandler = { request in
                try await configuredSession.data(for: request)
            }
        }
    }

    /// Mint one lease. The optional team id is only for callers that need to
    /// target a different team the signed-in user belongs to; normal callers
    /// pass nil and use AuthCoordinator.resolvedTeamID.
    func mint(teamID explicitTeamID: String? = nil) async throws -> CodeRouterHandoffLease {
        let snapshot: AuthenticatedSessionSnapshot
        do {
            snapshot = try await auth.authenticatedSessionSnapshot()
        } catch AuthError.unauthorized {
            throw CodeRouterHandoffClientError.notSignedIn
        } catch AuthError.offline, AuthError.networkError, AuthError.timedOut {
            throw CodeRouterHandoffClientError.sessionUnavailable
        } catch {
            // Unknown auth failures are not proof of sign-out. Keep the
            // response generic and retryable without exposing auth details.
            throw CodeRouterHandoffClientError.sessionUnavailable
        }

        let resolvedTeamID = await auth.codeRouterHandoffResolvedTeamID()
        let targetTeamID = try Self.validatedTeamID(explicitTeamID ?? resolvedTeamID)
        guard await auth.isAuthenticatedSessionCurrent(snapshot) else {
            throw CodeRouterHandoffClientError.sessionChanged
        }
        guard let baseURL else {
            throw CodeRouterHandoffClientError.invalidResponse
        }

        let request = try Self.makeRequest(
            baseURL: baseURL,
            accessToken: snapshot.accessToken,
            refreshToken: snapshot.refreshToken,
            teamID: targetTeamID
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await requestHandler(request)
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut,
                 .networkConnectionLost, .notConnectedToInternet,
                 .secureConnectionFailed:
                throw CodeRouterHandoffClientError.backendUnreachable
            default:
                throw CodeRouterHandoffClientError.sessionUnavailable
            }
        } catch {
            throw CodeRouterHandoffClientError.sessionUnavailable
        }

        guard let http = response as? HTTPURLResponse else {
            throw CodeRouterHandoffClientError.invalidResponse
        }
        guard http.url == request.url else {
            throw CodeRouterHandoffClientError.redirectedResponse
        }
        guard (200...299).contains(http.statusCode) else {
            // Never parse or return the response body. It may contain a lease,
            // Stack error text, or proxy diagnostics.
            throw CodeRouterHandoffClientError.httpStatus(http.statusCode)
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw CodeRouterHandoffClientError.invalidResponse
        }

        guard await auth.isAuthenticatedSessionCurrent(snapshot),
              await auth.codeRouterHandoffResolvedTeamID() == resolvedTeamID else {
            // The backend may already have created the lease. Do not return it
            // to a caller after a sign-out/account/team transition.
            throw CodeRouterHandoffClientError.sessionChanged
        }

        let lease = try Self.decodeLease(data, expectedTeamID: targetTeamID, now: clock())
        return lease
    }

    private static var defaultBaseURL: URL {
#if DEBUG
        // A tagged/local build may point at a local handoff server. The
        // validator below permits loopback only; arbitrary environment hosts
        // are ignored and fall back to the hosted origin.
        let configured = AuthEnvironment.vmAPIBaseURL
        if let allowed = allowedBaseURL(configured) {
            return allowed
        }
#endif
        return hostedOrigin
    }

    private static func allowedBaseURL(_ candidate: URL) -> URL? {
        guard var components = URLComponents(url: candidate, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            return nil
        }
        if host == "coderouter.dev" {
            guard components.scheme?.lowercased() == "https",
                  components.port == nil || components.port == 443 else {
                return nil
            }
            components.path = ""
            return components.url
        }
#if DEBUG
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard isLoopback,
              (components.scheme?.lowercased() == "http"
                || components.scheme?.lowercased() == "https") else {
            return nil
        }
        return candidate
#else
        return nil
#endif
    }

    private static func makeRequest(
        baseURL: URL,
        accessToken: String,
        refreshToken: String,
        teamID: String?
    ) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw CodeRouterHandoffClientError.invalidResponse
        }
        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = basePath + "/api/coderouter/handoff"
        // A base URL with a query or fragment is not a safe credential target.
        guard components.query == nil, components.fragment == nil,
              let url = components.url else {
            throw CodeRouterHandoffClientError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.httpTimeoutSeconds
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Ask intermediaries not to store a credential-bearing mint response.
        // The server also returns this directive; the request header is
        // defense in depth for compliant caches.
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        if let teamID {
            request.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data("{}".utf8)
        return request
    }

    private static func validatedTeamID(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 256,
              trimmed.unicodeScalars.allSatisfy({
                  !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw CodeRouterHandoffClientError.invalidTeam
        }
        return trimmed
    }

    private static func decodeLease(
        _ data: Data,
        expectedTeamID: String?,
        now: Date
    ) throws -> CodeRouterHandoffLease {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let teamID = object["teamId"] as? String,
              let lease = object["lease"] as? String,
              let expiresAt = object["expiresAt"] as? String,
              !teamID.isEmpty,
              !expiresAt.isEmpty,
              isValidLeaseSyntax(lease),
              expectedTeamID == nil || expectedTeamID == teamID else {
            throw CodeRouterHandoffClientError.invalidResponse
        }

        let formatter = ISO8601DateFormatter()
        guard let expiry = formatter.date(from: expiresAt), expiry > now else {
            throw CodeRouterHandoffClientError.expiredLease
        }
        return CodeRouterHandoffLease(teamID: teamID, lease: lease, expiresAt: expiresAt)
    }

    /// Protocol syntax is `crh_` plus exactly 43 URL-safe base64 characters.
    nonisolated static func isValidLeaseSyntax(_ value: String) -> Bool {
        let suffix = value.dropFirst(4)
        guard value.hasPrefix("crh_"), suffix.utf8.count == 43 else { return false }
        return suffix.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 95:
                return true
            default:
                return false
            }
        }
    }
}

extension CodeRouterHandoffClient: CodeRouterHandoffMinting {}

/// Narrow socket-facing capability. It keeps TerminalController independent
/// of the HTTP/auth implementation and allows runtime tests to inject a fake
/// minting service without touching global state.
protocol CodeRouterHandoffMinting: Sendable {
    func mint(teamID: String?) async throws -> CodeRouterHandoffLease
}
