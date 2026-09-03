import CmuxAuthRuntime
import CmuxControlSocket
import Foundation

enum CoderouterClientError: Error, CustomStringConvertible {
    case notSignedIn
    case sessionRefreshFailed
    case httpStatus(Int, String)
    case malformedResponse(String)
    case backendUnreachable(url: String, detail: String)

    var description: String {
        switch self {
        case .notSignedIn:
            return "Not signed in. Run `cmux auth login`, then retry."
        case .sessionRefreshFailed:
            return "Signed in, but cmux could not refresh your session (network or server issue). Retry in a moment."
        case let .httpStatus(status, body):
            return CoderouterClient.formatHTTPError(status: status, body: body)
        case let .malformedResponse(message):
            return "The coderouter service returned an unexpected response: \(message)"
        case let .backendUnreachable(url, detail):
            return "Could not reach the cmux backend at \(url): \(detail)"
        }
    }
}

/// The credential shapes `POST /api/coderouter/claude-upstream` accepts. A
/// team holds any number of accounts of any kind; adding one never replaces
/// another. Secrets travel from the CLI process over the local socket into
/// this actor and out to the cmux backend; they are never logged, echoed, or
/// persisted on the Mac.
enum ClaudeUpstreamInput: Sendable {
    case anthropicAPIKey(String)
    case anthropicOAuth(token: String)
    case bedrock(region: String, accessKeyID: String, secretAccessKey: String, sessionToken: String?, modelIDs: [String: String])

    var kind: String {
        switch self {
        case .anthropicAPIKey: return "anthropic_api_key"
        case .anthropicOAuth: return "anthropic_oauth"
        case .bedrock: return "bedrock"
        }
    }

    func jsonBody(label: String?) -> [String: Any] {
        var body: [String: Any]
        switch self {
        case let .anthropicAPIKey(apiKey):
            body = ["kind": kind, "apiKey": apiKey]
        case let .anthropicOAuth(token):
            body = ["kind": kind, "token": token]
        case let .bedrock(region, accessKeyID, secretAccessKey, sessionToken, modelIDs):
            body = [
                "kind": kind,
                "region": region,
                "accessKeyId": accessKeyID,
                "secretAccessKey": secretAccessKey,
            ]
            if let sessionToken, !sessionToken.isEmpty {
                body["sessionToken"] = sessionToken
            }
            if !modelIDs.isEmpty {
                body["modelIds"] = modelIDs
            }
        }
        if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            body["label"] = label
        }
        return body
    }
}

/// Team-level coderouter settings the app manages for the CLI (`cmux
/// coderouter ...`): the Claude upstream accounts and per-machine usage.
/// Same origin, session auth, and team header as `AIAccountsClient`; the
/// backend authorizes `manage` for writes and `use-or-manage` for reads.
actor CoderouterClient {
    @MainActor private(set) static var shared: CoderouterClient!

    @MainActor
    static func bootstrap(auth: AuthCoordinator, session: URLSession = .shared) {
        shared = CoderouterClient(session: session, auth: auth)
    }

    private let session: URLSession
    private let auth: AuthCoordinator

    init(session: URLSession = .shared, auth: AuthCoordinator) {
        self.session = session
        self.auth = auth
    }

    /// `{ teamId, accounts: [{ id, kind, label, identifier, region, modelIds,
    /// state, cooldownUntil, lastFailureCode, lastUsedAt, createdAt, updatedAt }],
    /// upstream }`. Identifiers are already masked by the server.
    func claudeAccounts(teamID: String?) async throws -> JSONValue {
        let (data, http) = try await request("GET", path: "/api/coderouter/claude-upstream", teamID: teamID)
        try ensureOK(http, data: data)
        return try bridgedJSONObject(data)
    }

    /// Adds an account. Returns `{ teamId, account, accountsTotal }`.
    func addClaudeAccount(_ input: ClaudeUpstreamInput, label: String?, teamID: String?) async throws -> JSONValue {
        let (data, http) = try await request(
            "POST",
            path: "/api/coderouter/claude-upstream",
            jsonBody: input.jsonBody(label: label),
            teamID: teamID
        )
        try ensureOK(http, data: data)
        return try bridgedJSONObject(data)
    }

    /// Renames or enables/disables one account. Returns `{ teamId, account }`.
    func updateClaudeAccount(id accountID: String, label: String?, state: String?, teamID: String?) async throws -> JSONValue {
        var body: [String: Any] = [:]
        if let label { body["label"] = label }
        if let state { body["state"] = state }
        let escaped = try pathSegment(accountID, fieldName: "account id")
        let (data, http) = try await request(
            "PATCH",
            path: "/api/coderouter/claude-upstream/\(escaped)",
            jsonBody: body,
            teamID: teamID
        )
        try ensureOK(http, data: data)
        return try bridgedJSONObject(data)
    }

    /// Removes one account. A 404 is reported as `removed: false` so `remove`
    /// is idempotent.
    func removeClaudeAccount(id accountID: String, teamID: String?) async throws -> JSONValue {
        let escaped = try pathSegment(accountID, fieldName: "account id")
        let (data, http) = try await request("DELETE", path: "/api/coderouter/claude-upstream/\(escaped)", teamID: teamID)
        if http.statusCode == 404 {
            return .object(["removed": .bool(false), "count": .int(0)])
        }
        try ensureOK(http, data: data)
        return try bridgedJSONObject(data)
    }

    /// Removes every account of the team. A 404 (nothing configured) is
    /// reported as `removed: false`.
    func clearClaudeAccounts(teamID: String?) async throws -> JSONValue {
        let (data, http) = try await request("DELETE", path: "/api/coderouter/claude-upstream", teamID: teamID)
        if http.statusCode == 404 {
            return .object(["removed": .bool(false), "count": .int(0)])
        }
        try ensureOK(http, data: data)
        return try bridgedJSONObject(data)
    }

    /// The team's subscription accounts (ChatGPT Codex, OpenCode Go) from
    /// `GET /api/coderouter/accounts`: `{ teamId, accounts: [{ id, provider,
    /// providerAccountId, label, state, cooldownUntil, lastFailureCode,
    /// activeSessions, usage?, usageError? }], usageAsOf }`.
    func subscriptionAccounts(teamID: String?) async throws -> JSONValue {
        let (data, http) = try await request("GET", path: "/api/coderouter/accounts", teamID: teamID)
        try ensureOK(http, data: data)
        return try bridgedJSONObject(data)
    }

    /// Removes one subscription account. A 404 is reported as `removed: false`.
    func removeSubscriptionAccount(id accountID: String, teamID: String?) async throws -> JSONValue {
        let escaped = try pathSegment(accountID, fieldName: "account id")
        let (data, http) = try await request("DELETE", path: "/api/coderouter/accounts/\(escaped)", teamID: teamID)
        if http.statusCode == 404 {
            return .object(["removed": .bool(false)])
        }
        try ensureOK(http, data: data)
        return try bridgedJSONObject(data)
    }

    /// Percent-encode a caller-provided value as a single URL path segment;
    /// `/`, `.`, and `..` would otherwise change the backend route.
    private func pathSegment(_ value: String, fieldName: String) throws -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed),
              !encoded.isEmpty, encoded != ".", encoded != ".." else {
            throw CoderouterClientError.malformedResponse("invalid \(fieldName)")
        }
        return encoded
    }

    private func bridgedJSONObject(_ data: Data) throws -> JSONValue {
        let object = try decodeJSONObject(data)
        guard let value = JSONValue(foundationObject: object) else {
            throw CoderouterClientError.malformedResponse("response is not valid JSON")
        }
        return value
    }

    private func request(
        _ method: String,
        path: String,
        jsonBody: [String: Any]? = nil,
        teamID explicitTeamID: String?
    ) async throws -> (Data, HTTPURLResponse) {
        let tokens: (accessToken: String, refreshToken: String)
        do {
            tokens = try await auth.currentTokens()
        } catch AuthError.networkError {
            throw CoderouterClientError.sessionRefreshFailed
        } catch {
            throw CoderouterClientError.notSignedIn
        }
        let resolvedTeamID = await auth.resolvedTeamID

        guard var comps = URLComponents(url: AuthEnvironment.vmAPIBaseURL, resolvingAgainstBaseURL: false) else {
            throw CoderouterClientError.malformedResponse("the cmux backend URL is misconfigured")
        }
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path) + path
        guard let url = comps.url else {
            throw CoderouterClientError.malformedResponse("could not build the request URL")
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
                throw CoderouterClientError.backendUnreachable(url: base, detail: error.localizedDescription)
            default:
                throw error
            }
        }
        guard let http = response as? HTTPURLResponse else {
            throw CoderouterClientError.malformedResponse("non-HTTP response")
        }
        return (data, http)
    }

    private func ensureOK(_ http: HTTPURLResponse, data: Data) throws {
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CoderouterClientError.httpStatus(http.statusCode, body)
        }
    }

    private func decodeJSONObject(_ data: Data) throws -> [String: Any] {
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        guard let obj = parsed as? [String: Any] else {
            throw CoderouterClientError.malformedResponse("expected a JSON object")
        }
        return obj
    }

    static func formatHTTPError(status: Int, body: String) -> String {
        if status == 401 {
            return "Not signed in or session expired. Run `cmux auth login`, then retry."
        }
        if status == 403 {
            return "This account cannot manage the team's coderouter settings."
        }
        if status == 404 {
            return "No Claude upstream account with that id exists on this team. Run `cmux coderouter claude list`."
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        var serverError: String?
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            let code = object["error"] as? String
            let message = object["message"] as? String
            serverError = [code, message].compactMap { $0 }.joined(separator: ": ")
        }
        if let serverError = serverError.map(AIAccountsClient.redactSecrets), !serverError.isEmpty {
            if status == 400 {
                return "coderouter rejected the request (HTTP 400): \(serverError). Check the credential format and retry."
            }
            return "coderouter request failed (HTTP \(status)): \(serverError)"
        }
        return "coderouter request failed (HTTP \(status))."
    }
}
