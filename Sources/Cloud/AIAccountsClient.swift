import CmuxAuthRuntime
import CmuxControlSocket
import Foundation

enum AIAccountsClientError: Error, CustomStringConvertible {
    case notSignedIn
    case httpStatus(Int, String)
    case malformedResponse(String)
    case backendUnreachable(url: String, detail: String)

    var description: String {
        switch self {
        case .notSignedIn:
            return "Not signed in. Run `cmux auth login`, then retry."
        case let .httpStatus(status, body):
            return AIAccountsClient.formatHTTPError(status: status, body: body)
        case let .malformedResponse(message):
            return "The AI accounts service returned an unexpected response: \(message)"
        case let .backendUnreachable(url, detail):
            return "Could not reach the cmux backend at \(url): \(detail)"
        }
    }
}

actor AIAccountsClient {
    @MainActor private(set) static var shared: AIAccountsClient!

    @MainActor
    static func bootstrap(auth: AuthCoordinator, session: URLSession = .shared) {
        shared = AIAccountsClient(session: session, auth: auth)
    }

    private let session: URLSession
    private let auth: AuthCoordinator

    init(session: URLSession = .shared, auth: AuthCoordinator) {
        self.session = session
        self.auth = auth
    }

    /// Public results are typed `JSONValue` trees so no untyped
    /// `JSONSerialization` dictionaries cross the actor boundary;
    /// `[String: Any]` stays private to the HTTP request/decode path below.
    func list(teamID: String?) async throws -> [JSONValue] {
        let (data, http) = try await request("GET", path: "/api/subrouter/accounts", teamID: teamID)
        try ensureOK(http, data: data)
        let object = try decodeJSONObject(data)
        guard let accounts = object["accounts"] as? [[String: Any]] else {
            throw AIAccountsClientError.malformedResponse("missing `accounts` array")
        }
        return try accounts.map { account in
            guard let value = JSONValue(foundationObject: account) else {
                throw AIAccountsClientError.malformedResponse("account entry is not valid JSON")
            }
            return value
        }
    }

    func upload(_ payload: AIAccountUploadPayload, teamID: String?, validate: Bool) async throws -> JSONValue {
        let queryItems = validate ? [URLQueryItem(name: "validate", value: "1")] : []
        let (data, http) = try await request(
            "POST",
            path: "/api/subrouter/accounts",
            queryItems: queryItems,
            jsonBody: payload.jsonBody,
            teamID: teamID
        )
        try ensureOK(http, data: data)
        return try bridgedJSONObject(data)
    }

    func remove(id accountID: String, teamID: String?) async throws -> JSONValue {
        let escaped = try pathSegment(accountID, fieldName: "account id")
        let (data, http) = try await request("DELETE", path: "/api/subrouter/accounts/\(escaped)", teamID: teamID)
        try ensureOK(http, data: data)
        return try bridgedJSONObject(data)
    }

    /// Percent-encode a caller-provided value as a single URL path segment.
    /// `.urlPathAllowed` permits `/`, so ids from socket/CLI params could
    /// otherwise inject extra path components into the request URL; `.` and
    /// `..` are rejected because URL normalization would resolve them into a
    /// different backend route instead of an account-id segment.
    private func pathSegment(_ value: String, fieldName: String) throws -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed),
              !encoded.isEmpty, encoded != ".", encoded != ".." else {
            throw AIAccountsClientError.malformedResponse("invalid \(fieldName)")
        }
        return encoded
    }

    private func bridgedJSONObject(_ data: Data) throws -> JSONValue {
        let object = try decodeJSONObject(data)
        guard let value = JSONValue(foundationObject: object) else {
            throw AIAccountsClientError.malformedResponse("response is not valid JSON")
        }
        return value
    }

    private func request(
        _ method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        jsonBody: [String: Any]? = nil,
        teamID explicitTeamID: String?
    ) async throws -> (Data, HTTPURLResponse) {
        let tokens: (accessToken: String, refreshToken: String)
        do {
            tokens = try await auth.currentTokens()
        } catch {
            throw AIAccountsClientError.notSignedIn
        }
        let resolvedTeamID = await auth.resolvedTeamID

        guard var comps = URLComponents(url: AuthEnvironment.vmAPIBaseURL, resolvingAgainstBaseURL: false) else {
            throw AIAccountsClientError.malformedResponse("the cmux backend URL is misconfigured")
        }
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path) + path
        if !queryItems.isEmpty {
            comps.queryItems = queryItems
        }
        guard let url = comps.url else {
            throw AIAccountsClientError.malformedResponse("could not build the request URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(tokens.refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        let teamID = explicitTeamID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let teamID = teamID?.isEmpty == false ? teamID : resolvedTeamID, !teamID.isEmpty {
            req.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody, options: [])
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet:
                let base = "\(AuthEnvironment.vmAPIBaseURL.scheme ?? "http")://\(AuthEnvironment.vmAPIBaseURL.host ?? "?"):\(AuthEnvironment.vmAPIBaseURL.port ?? -1)"
                throw AIAccountsClientError.backendUnreachable(url: base, detail: error.localizedDescription)
            default:
                throw error
            }
        }
        guard let http = response as? HTTPURLResponse else {
            throw AIAccountsClientError.malformedResponse("non-HTTP response")
        }
        return (data, http)
    }

    private func ensureOK(_ http: HTTPURLResponse, data: Data) throws {
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIAccountsClientError.httpStatus(http.statusCode, body)
        }
    }

    private func decodeJSONObject(_ data: Data) throws -> [String: Any] {
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        guard let obj = parsed as? [String: Any] else {
            throw AIAccountsClientError.malformedResponse("expected a JSON object")
        }
        return obj
    }

    static func formatHTTPError(status: Int, body: String) -> String {
        if status == 503 {
            return "AI accounts are not configured on this cmux backend."
        }
        if status == 401 {
            return "Not signed in or session expired. Run `cmux auth login`, then retry."
        }

        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        var serverError: String?
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
           let value = object["error"] as? String {
            serverError = redactSecrets(value)
        }
        if let serverError, !serverError.isEmpty {
            return "AI accounts request failed (HTTP \(status)): \(serverError)"
        }
        return "AI accounts request failed (HTTP \(status))."
    }

    static func redactSecrets(_ value: String) -> String {
        var redacted = value
        let patterns = [
            #"sk-[A-Za-z0-9_\-]{8,}"#,
            #"sk-ant-[A-Za-z0-9_\-]{8,}"#,
            #"(?i)(access[_-]?token|refresh[_-]?token|id[_-]?token|api[_-]?key)["':=\s]+[A-Za-z0-9._\-]{8,}"#,
            #"(?i)bearer\s+[A-Za-z0-9._\-]{8,}"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
            redacted = regex.stringByReplacingMatches(in: redacted, range: range, withTemplate: "<redacted>")
        }
        return redacted
    }
}
