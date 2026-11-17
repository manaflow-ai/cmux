public import Foundation

/// The new chat folder picker's GitHub section: the person's repositories the cmux GitHub App reaches
/// for their team (`GET /v1/integrations/github/repos?team=&query=`, with their own session), as the
/// page's `github.repos.list` answers them. A team with no installation is ``Failure/notConnected``:
/// the picker offers Connect GitHub.
public struct CloudGitHubRepos: Equatable, Sendable {
    public struct Repo: Equatable, Sendable {
        /// `owner/name`.
        public var fullName: String
        public var isPrivate: Bool
        public var defaultBranch: String?

        public init(fullName: String, isPrivate: Bool, defaultBranch: String?) {
            (self.fullName, self.isPrivate, self.defaultBranch) = (fullName, isPrivate, defaultBranch)
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// The team has no usable installation (`integration.not_found`), or it must be linked again (`needs_reauth`).
        case notConnected
        /// Signed out, offline, the route is not there, or GitHub did not answer.
        case unavailable
    }

    public var repos: [Repo]
    /// The listing stopped before the last repository: the person narrows it with a query.
    public var truncated: Bool

    public init(repos: [Repo], truncated: Bool) {
        (self.repos, self.truncated) = (repos, truncated)
    }

    /// The route's answer: `{repos: [{full_name, private, default_branch}], truncated}` (an older Worker
    /// pages with `cursor` instead), else `{error: {code, message}}`. A row that does not name `owner/name`
    /// is dropped, so no other text reaches the page.
    public static func parse(status: Int, body: Data) -> Result<CloudGitHubRepos, Failure> {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        guard (200..<300).contains(status), let object, let rows = object["repos"] as? [Any] else {
            let code = (object?["error"] as? [String: Any])?["code"] as? String
            return .failure(code == "integration.not_found" || code == "needs_reauth" ? .notConnected : .unavailable)
        }
        let repos = rows.compactMap { row -> Repo? in
            guard let row = row as? [String: Any], let name = row["full_name"] as? String, isFullName(name) else { return nil }
            let branch = (row["default_branch"] as? String).flatMap { $0.isEmpty || $0.utf8.count > 255 ? nil : $0 }
            return Repo(fullName: name, isPrivate: row["private"] as? Bool ?? true, defaultBranch: branch)
        }
        return .success(CloudGitHubRepos(repos: repos, truncated: object["truncated"] as? Bool ?? (object["cursor"] is String)))
    }

    /// GitHub's `owner/name`: an owner of letters, digits and `-`, and a name of letters, digits, `.`, `_` and `-`
    /// (never `.`, `..` or `.git`; an owner neither starts nor ends with `-`).
    public static func isFullName(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...39).contains(parts[0].utf8.count), (1...100).contains(parts[1].utf8.count),
              parts[1] != ".", parts[1] != "..", parts[1] != ".git", !parts[0].hasPrefix("-"), !parts[0].hasSuffix("-") else { return false }
        return parts[0].utf8.allSatisfy(ownerBytes.contains) && parts[1].utf8.allSatisfy(nameBytes.contains)
    }

    /// The route's path for `team` (a `team_…` id, as ``CloudGitHubApp/path(team:)`` takes it) and the
    /// person's search text, percent-encoded; nil for any other team.
    public static func path(team: String, query: String?) -> String? {
        guard let status = CloudGitHubApp.path(team: team) else { return nil }
        let base = status.replacingOccurrences(of: "/status?", with: "/repos?")
        let text = query?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256) ?? ""
        guard !text.isEmpty, let encoded = String(text).addingPercentEncoding(withAllowedCharacters: queryBytes) else { return base }
        return base + "&query=" + encoded
    }

    private static let ownerBytes = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-".utf8)
    private static let nameBytes = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._".utf8)
    private static let queryBytes = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
}

extension CloudGitHubApp {
    /// Which repositories a ready connection reaches (`repos_scope`): `all` when the status names no list
    /// (`connection.repos: null`), `selected` when it names one; nil when not ready.
    public static func reposScope(status: Int, body: Data) -> String? {
        guard CloudGitHubApp(status: status, body: body) == .ready,
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let connection = object["connection"] as? [String: Any] else { return nil }
        return connection["repos"] is [Any] ? "selected" : "all"
    }
}

extension CloudOwnerAPIClient {
    /// `GET /v1/integrations/github/status?team=`: the App's state for `team` and, when ready, which
    /// repositories it reaches. Never throws: a check that does not answer is ``CloudGitHubApp/unknown``.
    public func gitHubAppStatus(team: String) async -> (app: CloudGitHubApp, reposScope: String?) {
        guard let path = CloudGitHubApp.path(team: team), let answer = await person(path) else { return (.unknown, nil) }
        return (CloudGitHubApp(status: answer.status, body: answer.body), CloudGitHubApp.reposScope(status: answer.status, body: answer.body))
    }

    /// `GET /v1/integrations/github/repos?team=&query=` with the person's own session.
    public func gitHubRepos(team: String, query: String?) async -> Result<CloudGitHubRepos, CloudGitHubRepos.Failure> {
        guard let path = CloudGitHubRepos.path(team: team, query: query), let answer = await person(path) else { return .failure(.unavailable) }
        return CloudGitHubRepos.parse(status: answer.status, body: answer.body)
    }

    /// `integration.connect {provider: "github"}` on `/v1/ops`, as the person, in ``teamID``'s team (`x-cmux-team`), under
    /// `key`: a replay of the key answers the same pending connection and page.
    public func gitHubConnect(key: String) async -> CloudGitHubConnects.Answer {
        let body: [String: Any] = ["op": "integration.connect", "params": ["provider": "github"], "origin": "user", "idempotency_key": key]
        guard let json = try? JSONSerialization.data(withJSONObject: body), let answer = await person("/v1/ops", post: json) else { return .noAnswer }
        return CloudGitHubConnects.answer(status: answer.status, body: answer.body)
    }

    /// `integration.list` on `/v1/read` in ``teamID``'s team: whether a GitHub connection this person sees is pending
    /// (Settings' Connect, or another launch's); nil when it did not answer.
    public func gitHubConnectPending() async -> Bool? {
        guard let json = try? JSONSerialization.data(withJSONObject: ["op": "integration.list", "params": [String: Any]()]),
              let answer = await person("/v1/read", post: json) else { return nil }
        return CloudGitHubConnects.pending(status: answer.status, body: answer.body)
    }

    /// One GET of `path` (a POST of `post` in ``teamID``'s team when given) with only Authorization (the Worker's
    /// invocation log masks it); nil when it did not answer.
    func person(_ path: String, post: Data? = nil) async -> (status: Int, body: Data)? {
        guard let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path),
              let access = try? await accessToken() else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = post == nil ? "GET" : "POST"
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        if let post {
            request.httpBody = post
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let team = await teamID() { request.setValue(team, forHTTPHeaderField: "x-cmux-team") }
        }
        let session = session, prepared = request, label = "\(request.httpMethod ?? "GET") \(url.path)"
        guard let answer = try? await withDeadline(.seconds(15), label: label, { try await session.data(for: prepared) }),
              let http = answer.1 as? HTTPURLResponse else { return nil }
        return (http.statusCode, answer.0)
    }
}

/// Each team's Connect GitHub from the picker this launch, as Settings' Connect GitHub keeps its own: the installation
/// page `integration.connect` answered, opened again until its signed state expires, and the idempotency key that
/// asked, kept while its answer may have been lost. A second click never adds another pending connection.
@MainActor
public final class CloudGitHubConnects {
    /// What one `integration.connect` answered.
    public enum Answer: Equatable, Sendable {
        case page(URL)
        /// A definitive refusal or a reply this client will not use: the next click asks with a new key.
        case refused
        /// No answer, a timeout, throttling or a server failure: the connect may have happened, so the key stays.
        case noAnswer
    }

    private var flows: [String: (key: String, page: URL?)] = [:]
    private let newKey: () -> String

    public init(newKey: @escaping () -> String = { UUID().uuidString }) { self.newKey = newKey }

    /// The page to open for `team` at `now`: the one asked before while it holds, else what `ask(key)` answers.
    public func page(team: String, now: Date, ask: (String) async -> Answer) async -> URL? {
        if let page = flows[team]?.page {
            if let expires = CloudGitHubApp.authorizationExpiry(page), expires > now { return page }
            flows[team] = nil
        }
        let key = flows[team]?.key ?? newKey()
        flows[team] = (key, nil)
        let answer = await ask(key)
        guard flows[team]?.key == key else { if case .page(let url) = answer { return url }; return nil } // another click asked meanwhile
        switch answer {
        case .page(let url): flows[team] = (key, url); return url
        case .refused: flows[team] = nil; return nil
        case .noAnswer: return nil
        }
    }

    /// Whether this launch's picker holds a flow for `team` it can resume (its page, or a key whose answer may be lost).
    public func resumable(team: String) -> Bool { flows[team] != nil }

    /// The `integration.list` reply `{value: {connections: [{provider, status}]}}`: whether a GitHub one is pending; nil for any other reply.
    nonisolated static func pending(status: Int, body: Data) -> Bool? {
        guard (200..<300).contains(status), let reply = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], reply["ok"] as? Bool != false,
              let rows = (reply["value"] as? [String: Any])?["connections"] as? [Any] else { return nil }
        return rows.contains { row in
            guard let row = row as? [String: Any] else { return false }
            return row["provider"] as? String == "github" && row["status"] as? String == "pending"
        }
    }

    /// The `/v1/ops` reply: `{ok, value: {authorize_url, connection: {id}}}` with a page ``CloudGitHubApp/installationURL(_:)`` allows.
    nonisolated static func answer(status: Int, body: Data) -> Answer {
        guard status < 500, status != 408, status != 429 else { return .noAnswer }
        let reply = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        guard (200..<300).contains(status), let reply, reply["error"] == nil || reply["error"] is NSNull, reply["ok"] as? Bool != false,
              let value = reply["value"] as? [String: Any], let raw = value["authorize_url"] as? String, let url = CloudGitHubApp.installationURL(raw),
              let id = (value["connection"] as? [String: Any])?["id"] as? String, !id.isEmpty else { return .refused }
        return .page(url)
    }
}

/// The picker's reads and its Connect GitHub as the signed-in person of `auth`, against the owner API, in the team a
/// Cloud start makes its new machine in (``owner()``): the machine mints its GitHub token there, so the picker lists
/// only repositories that machine can clone.
@MainActor
public struct CloudGitHubPicker {
    public let auth: CloudAuth
    /// The install whose token's team a Cloud start's create bills.
    public let identity: MacInstallIdentity
    let connects: CloudGitHubConnects

    /// How long the picker waits for this launch's first install bind (a bound install answers at once).
    static let bindWait: Duration = .seconds(8)

    public init(auth: CloudAuth, identity: MacInstallIdentity, connects: CloudGitHubConnects = CloudGitHubConnects()) {
        (self.auth, self.identity, self.connects) = (auth, identity, connects)
    }

    /// The client and the team of the install token's `team` claim: the team `CloudService.appServerCreate` makes a
    /// Cloud start's machine in, the active team or not (the active team can be another one, and with none the
    /// picker still has this team). Nil signed out, or when the token names no team. Right after launch the restored
    /// sign-in may not have bound the install yet: the token waits up to ``bindWait`` for it, as the credential relay's.
    func owner() async -> (client: CloudOwnerAPIClient, team: String)? {
        guard auth.isSignedIn, let token = try? await identity.installToken(awaitingBind: Self.bindWait),
              let team = MacInstallIdentity.team(ofToken: token) else { return nil }
        let auth = auth
        let access: CloudOwnerAPIClient.AccessToken = { try await auth.tokens().access }
        return (CloudOwnerAPIClient(baseURL: auth.configuration.ownerAPIBaseURL(), accessToken: access, teamID: { team }), team)
    }

    /// `github.status`'s `state` and `repos_scope`: `ready`, `not_connected`, or `unavailable` (signed
    /// out, no App in this deployment, a team policy that disallows GitHub, or no answer).
    public func status() async -> (state: String, reposScope: String?) {
        guard let owner = await owner() else { return ("unavailable", nil) }
        let (app, scope) = await owner.client.gitHubAppStatus(team: owner.team)
        switch app {
        case .ready: return ("ready", scope)
        case .notConnected: return ("not_connected", nil)
        case .notConfigured, .unknown: return ("unavailable", nil)
        }
    }

    /// `github.repos.list`.
    public func repos(query: String?) async -> Result<CloudGitHubRepos, CloudGitHubRepos.Failure> {
        guard let owner = await owner() else { return .failure(.unavailable) }
        return await owner.client.gitHubRepos(team: owner.team, query: query)
    }

    /// What the status route alone settles for `github.connect`; nil when the team has no connection (ask `integration.connect`).
    /// A connected team opens its installation settings, or, when the status names none (an older Worker, or one whose
    /// GitHub lookup failed), opens nothing: `integration.connect` would add a second connection for the same installation.
    nonisolated static func connectFromStatus(status: Int, body: Data) -> Connect? {
        switch CloudGitHubApp(status: status, body: body) {
        case .ready: CloudGitHubApp.configureURL(status: status, body: body).map(Connect.open) ?? .connected
        case .notConnected: nil
        case .notConfigured, .unknown: .unavailable
        }
    }

    /// What `github.connect` does.
    public enum Connect: Equatable, Sendable {
        /// Open this page in the person's browser.
        case open(URL)
        /// The team is connected already: nothing to open.
        case connected
        /// A connection this picker can't resume is pending (Settings' Connect, another launch's): finish that one.
        case pending
        /// Signed out, no App here, a team policy that disallows GitHub, or no answer.
        case unavailable
    }

    /// `github.connect` for the team ``owner()`` names (Settings' Connect GitHub asks in the active team, which can be
    /// another one): a connected team's installation settings, where the person adds repositories (More repositories);
    /// a team with no connection, the App's installation page from `integration.connect` in that team.
    public func connect() async -> Connect {
        guard let owner = await owner(), let path = CloudGitHubApp.path(team: owner.team),
              let status = await owner.client.person(path) else { return .unavailable }
        if let known = Self.connectFromStatus(status: status.status, body: status.body) { return known }
        let client = owner.client
        // As Settings' Connect (`!pending || resumable`): another connect beside a pending one would add a second.
        if !connects.resumable(team: owner.team) {
            switch await client.gitHubConnectPending() {
            case false?: break
            case true?: return .pending
            case nil: return .unavailable
            }
        }
        guard let page = await connects.page(team: owner.team, now: Date(), ask: { await client.gitHubConnect(key: $0) }) else { return .unavailable }
        return .open(page)
    }
}
