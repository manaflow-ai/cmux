import CmuxAuthRuntime
import CmuxWorkspaceShare
import Foundation

/// Web API client for the share-session endpoints. Mirrors `VMClient`'s auth
/// (Stack tokens from the injected `AuthCoordinator`) and base-URL resolution
/// (`AuthEnvironment.vmAPIBaseURL`, i.e. the same web origin the Cloud VM
/// backend uses), with an extra `CMUX_SHARE_API_BASE_URL` env override.
struct ShareSessionCreateResult: Decodable, Sendable {
    let code: String
    let token: String
    /// Unix seconds.
    let expiresAt: Double
    let wsUrl: String
    let shareUrl: String
}

struct ShareTokenResult: Decodable, Sendable {
    let token: String
    /// Unix seconds.
    let expiresAt: Double
    let wsUrl: String
}

enum ShareSessionAPIError: Error, CustomStringConvertible, Sendable {
    case notSignedIn
    case httpStatus(Int, retryAfter: Duration?)
    case malformedResponse(String)

    var description: String {
        switch self {
        case .notSignedIn:
            return "Not signed in to cmux."
        case .httpStatus(let code, _):
            return "Share API request failed (HTTP \(code))."
        case .malformedResponse(let message):
            return "Share API returned an unreadable response: \(message)"
        }
    }

    var lifecycleFailure: WorkspaceShareSessionLifecycle.Failure {
        switch self {
        case .notSignedIn:
            return .http(statusCode: 401, retryAfter: nil)
        case .httpStatus(let statusCode, let retryAfter):
            return .http(statusCode: statusCode, retryAfter: retryAfter)
        case .malformedResponse:
            return .invalidEndpoint
        }
    }
}

actor ShareSessionAPI {
    private static let maximumResponseBytes = 64 * 1_024
    private let session: URLSession
    private let auth: AuthCoordinator

    init(auth: AuthCoordinator, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    static var baseURL: URL {
        if let overridden = ProcessInfo.processInfo.environment["CMUX_SHARE_API_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridden.isEmpty,
           let url = URL(string: overridden) {
            return url
        }
        return AuthEnvironment.vmAPIBaseURL
    }

    /// `POST /api/share/sessions` — mint the share code and host token.
    func createSession() async throws -> ShareSessionCreateResult {
        let data = try await request("POST", path: "/api/share/sessions", jsonBody: [:])
        let result = try decode(ShareSessionCreateResult.self, from: data)
        guard WorkspaceShareGrantValidator.isValidCode(result.code),
              WorkspaceShareGrantValidator.isValidToken(result.token),
              WorkspaceShareGrantValidator.isValidExpiration(result.expiresAt),
              WorkspaceShareGrantValidator.webSocketURL(from: result.wsUrl) != nil,
              WorkspaceShareGrantValidator.sharePageURL(from: result.shareUrl) != nil else {
            throw ShareSessionAPIError.malformedResponse(
                "share grant fields failed validation"
            )
        }
        return result
    }

    /// `POST /api/share/sessions/<code>/token` with `{"host": true}` — a fresh
    /// host-claim token for reconnecting after the create-time token expired.
    func hostToken(code: String) async throws -> ShareTokenResult {
        guard WorkspaceShareGrantValidator.isValidCode(code),
              let encoded = code.addingPercentEncoding(
                  withAllowedCharacters: .urlPathAllowed
              ) else {
            throw ShareSessionAPIError.malformedResponse("share code is not URL-encodable")
        }
        let data = try await request(
            "POST",
            path: "/api/share/sessions/\(encoded)/token",
            jsonBody: ["host": true]
        )
        let result = try decode(ShareTokenResult.self, from: data)
        guard WorkspaceShareGrantValidator.isValidToken(result.token),
              WorkspaceShareGrantValidator.isValidExpiration(result.expiresAt),
              WorkspaceShareGrantValidator.webSocketURL(from: result.wsUrl) != nil else {
            throw ShareSessionAPIError.malformedResponse(
                "share token fields failed validation"
            )
        }
        return result
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ShareSessionAPIError.malformedResponse(String(describing: error))
        }
    }

    private func request(
        _ method: String,
        path: String,
        jsonBody: [String: Any]? = nil
    ) async throws -> Data {
        let tokens: (accessToken: String, refreshToken: String)
        do {
            tokens = try await auth.currentTokens()
        } catch {
            throw ShareSessionAPIError.notSignedIn
        }

        let baseURL = Self.baseURL
        guard WorkspaceShareGrantValidator.sharePageURL(
            from: baseURL.absoluteString
        ) != nil,
        var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw ShareSessionAPIError.malformedResponse("bad share API base URL")
        }
        components.path = (components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path) + path
        guard let url = components.url else {
            throw ShareSessionAPIError.malformedResponse("could not build URL for \(path)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(tokens.refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody, options: [])
        }

        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw ShareSessionAPIError.malformedResponse("non-HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let retryAfter = Self.retryAfter(
                from: http.value(forHTTPHeaderField: "Retry-After")
            )
            bytes.task.cancel()
            throw ShareSessionAPIError.httpStatus(
                http.statusCode,
                retryAfter: retryAfter
            )
        }
        if response.expectedContentLength > Self.maximumResponseBytes {
            bytes.task.cancel()
            throw ShareSessionAPIError.malformedResponse(
                "share API response exceeded its byte limit"
            )
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(
                min(Int(response.expectedContentLength), Self.maximumResponseBytes)
            )
        }
        do {
            for try await byte in bytes {
                guard data.count < Self.maximumResponseBytes else {
                    bytes.task.cancel()
                    throw ShareSessionAPIError.malformedResponse(
                        "share API response exceeded its byte limit"
                    )
                }
                data.append(byte)
            }
            return data
        } catch let error as ShareSessionAPIError {
            throw error
        } catch {
            bytes.task.cancel()
            throw error
        }
    }

    private static func retryAfter(from rawValue: String?) -> Duration? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 4,
              value.utf8.allSatisfy({ (48...57).contains($0) }),
              let seconds = Int(value),
              (1...3_600).contains(seconds) else {
            return nil
        }
        return .seconds(seconds)
    }
}
