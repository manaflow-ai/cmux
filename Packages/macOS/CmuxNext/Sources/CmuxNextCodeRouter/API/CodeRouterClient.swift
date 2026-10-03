import CmuxNextCloud
public import Foundation

/// A CodeRouter control-plane failure. Messages come from the server's
/// `error` / `message` fields (which never echo a credential) or name the
/// failure; a request body is never included.
public enum CodeRouterError: Error, Sendable, Equatable, CustomStringConvertible {
    case notSignedIn
    case timedOut(String)
    case http(status: Int, code: String?, message: String?)
    case transport(String)
    case decoding(String)

    public var description: String {
        switch self {
        case .notSignedIn: "not signed in to cmux"
        case .timedOut(let path): "\(path) timed out"
        case .http(let status, let code, let message): message ?? code.map { "\($0) (\(status))" } ?? "HTTP \(status)"
        case .transport(let detail): detail
        case .decoding(let detail): "unexpected response: \(detail)"
        }
    }
}

/// The CodeRouter control plane under `/api/coderouter/*`, authenticated
/// as the signed-in cmux user exactly like `/api/vm`: `Authorization:
/// Bearer <access>`, `X-Stack-Refresh-Token`, and the team in
/// `X-Cmux-Team-Id`. Tokens come from the caller per request and are never
/// stored. Every call has a deadline.
///
/// This is the privacy boundary for account identities: what leaves the
/// client carries ``AccountLabel``s (an `acct_…` handle and a redacted
/// display), never a server label that is an email.
public struct CodeRouterClient: Sendable {
    public typealias Tokens = @Sendable () async throws -> (access: String, refresh: String)
    public typealias TeamID = @Sendable () async -> String?
    public typealias Labeler = @Sendable () async -> AccountLabeler

    public let baseURL: URL
    let tokens: Tokens
    let teamID: TeamID
    let labeler: Labeler
    let session: URLSession
    let timeout: Duration

    public init(baseURL: URL, tokens: @escaping Tokens, teamID: @escaping TeamID, labeler: @escaping Labeler,
                session: URLSession = .shared, timeout: Duration = .seconds(15)) {
        self.baseURL = baseURL
        self.tokens = tokens
        self.teamID = teamID
        self.labeler = labeler
        self.session = session
        self.timeout = timeout
    }

    /// Every account the team's CodeRouter holds that this user may see.
    public func linkedAccounts() async throws -> [LinkedAccount] {
        struct Native: Decodable { var accounts: [NativeAccountRow] }
        struct Claude: Decodable { var accounts: [ClaudeAccountRow] }
        async let native = decode(Native.self, try await send("GET", "/api/coderouter/accounts"))
        async let claude = decode(Claude.self, try await send("GET", "/api/coderouter/claude-upstream"))
        let labeler = await labeler()
        return try await native.accounts.compactMap { LinkedAccount(native: $0, labeler: labeler) }
            + claude.accounts.compactMap { LinkedAccount(claude: $0, labeler: labeler) }
    }

    /// One control-plane request with an optional team override, returning
    /// the JSON body with every account identity redacted
    /// (``AccountJSONRedactor``). The `coderouter.*` socket methods pass
    /// this through to the CLI, MCP and apps.
    public func request(_ method: String, _ path: String, body: [String: any Sendable]? = nil,
                        team override: String? = nil) async throws -> Data {
        let data = try await send(method, path, body: body, team: override)
        return AccountJSONRedactor(labeler: await labeler(), accountRows: AccountJSONRedactor.isAccountEndpoint(path)).redact(data)
    }

    /// Adds an account. Re-adding the same sign-in or key updates it.
    public func add(_ credential: CodeRouterCredential) async throws {
        let path = credential.family == .native ? "/api/coderouter/accounts" : "/api/coderouter/claude-upstream"
        _ = try await send("POST", path, body: credential.body)
    }

    /// Removes one account. Returns false when it no longer existed.
    @discardableResult
    public func remove(_ account: LinkedAccount) async throws -> Bool {
        let base = account.family == .native ? "/api/coderouter/accounts/" : "/api/coderouter/claude-upstream/"
        do {
            _ = try await send("DELETE", base + (try Self.pathSegment(account.id)))
            return true
        } catch CodeRouterError.http(status: 404, _, _) {
            return false
        }
    }

    /// One control-plane request with an optional team override, returning
    /// the raw JSON body. Internal: callers outside the client use
    /// ``request(_:_:body:team:)``, which redacts account identities.
    func send(_ method: String, _ path: String, body: [String: any Sendable]? = nil,
                     team override: String? = nil) async throws -> Data {
        let (access, refresh): (String, String)
        do { (access, refresh) = try await tokens() } catch { throw CodeRouterError.notSignedIn }
        guard let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw CodeRouterError.transport("bad path")
        }
        var request = URLRequest(url: url, timeoutInterval: TimeInterval(timeout.components.seconds) + 1)
        request.httpMethod = method
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue(refresh, forHTTPHeaderField: "X-Stack-Refresh-Token")
        request.setValue("cmux-mac", forHTTPHeaderField: "X-Cmux-Client")
        let team = override?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let team = team?.isEmpty == false ? team : await teamID() {
            request.setValue(team, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let session = session, prepared = request
        let data: Data, response: URLResponse
        do {
            (data, response) = try await withDeadline(timeout, label: "\(method) \(path)") { try await session.data(for: prepared) }
        } catch is DeadlineExceeded {
            throw CodeRouterError.timedOut(path)
        } catch let error as URLError where error.code == .timedOut {
            throw CodeRouterError.timedOut(path)
        } catch {
            throw CodeRouterError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw CodeRouterError.transport("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else { throw Self.failure(status: http.statusCode, data: data) }
        return data
    }

    static func failure(status: Int, data: Data) -> CodeRouterError {
        if status == 401 { return .notSignedIn }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = (object?["error"] as? String).map(EmailRedaction.redactEmails(in:))
        let message = (object?["message"] as? String).flatMap { $0.isEmpty ? nil : EmailRedaction.redactEmails(in: String($0.prefix(300))) }
        return .http(status: status, code: code, message: message)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw CodeRouterError.decoding(String(describing: T.self)) }
    }

    /// A single path segment; `/`, `.` and `..` would change the route.
    static func pathSegment(_ value: String) throws -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed), !encoded.isEmpty,
              encoded != ".", encoded != ".." else { throw CodeRouterError.transport("invalid account id") }
        return encoded
    }
}
