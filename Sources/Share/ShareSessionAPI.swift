import CmuxAuthRuntime
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

enum ShareSessionAPIError: Error, CustomStringConvertible {
    case notSignedIn
    case httpStatus(Int, String)
    case malformedResponse(String)

    var description: String {
        switch self {
        case .notSignedIn:
            return "Not signed in to cmux."
        case .httpStatus(let code, let body):
            return "Share API request failed (HTTP \(code)): \(body)"
        case .malformedResponse(let message):
            return "Share API returned an unreadable response: \(message)"
        }
    }
}

actor ShareSessionAPI {
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
        return try decode(ShareSessionCreateResult.self, from: data)
    }

    /// `POST /api/share/sessions/<code>/token` with `{"host": true}` — a fresh
    /// host-claim token for reconnecting after the create-time token expired.
    func hostToken(code: String) async throws -> ShareTokenResult {
        guard let encoded = code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw ShareSessionAPIError.malformedResponse("share code is not URL-encodable")
        }
        let data = try await request(
            "POST",
            path: "/api/share/sessions/\(encoded)/token",
            jsonBody: ["host": true]
        )
        return try decode(ShareTokenResult.self, from: data)
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

        guard var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false) else {
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

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ShareSessionAPIError.malformedResponse("non-HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data.prefix(512), encoding: .utf8) ?? ""
            throw ShareSessionAPIError.httpStatus(http.statusCode, body)
        }
        return data
    }
}
