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
        guard let path = CloudGitHubApp.path(team: team), let answer = await personGet(path) else { return (.unknown, nil) }
        return (CloudGitHubApp(status: answer.status, body: answer.body), CloudGitHubApp.reposScope(status: answer.status, body: answer.body))
    }

    /// `GET /v1/integrations/github/repos?team=&query=` with the person's own session.
    public func gitHubRepos(team: String, query: String?) async -> Result<CloudGitHubRepos, CloudGitHubRepos.Failure> {
        guard let path = CloudGitHubRepos.path(team: team, query: query), let answer = await personGet(path) else { return .failure(.unavailable) }
        return CloudGitHubRepos.parse(status: answer.status, body: answer.body)
    }

    /// One GET of `path` with only Authorization (the Worker's invocation log masks it) and the build space (the
    /// build's public tag); nil when it did not answer, or when a misconfigured dev build has no space to send.
    func personGet(_ path: String) async -> (status: Int, body: Data)? {
        guard let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path),
              let access = try? await accessToken() else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        guard (try? buildSpace.apply(to: &request)) != nil else { return nil }
        let session = session, prepared = request
        guard let answer = try? await withDeadline(.seconds(15), label: "GET \(url.path)", { try await session.data(for: prepared) }),
              let http = answer.1 as? HTTPURLResponse else { return nil }
        return (http.statusCode, answer.0)
    }
}

/// The picker's reads as the signed-in person of `auth`, in the team `cmux auth token` mints for
/// (the backend `team_…` id, ``CloudAuth/accessTokenTeam(requested:)``), against the owner API.
@MainActor
public struct CloudGitHubPicker {
    public let auth: CloudAuth

    public init(auth: CloudAuth) { self.auth = auth }

    /// The client and team, or nil signed out (or with no team).
    func owner() -> (client: CloudOwnerAPIClient, team: String)? {
        guard auth.isSignedIn, let team = try? auth.accessTokenTeam(requested: nil) else { return nil }
        let auth = auth
        let access: CloudOwnerAPIClient.AccessToken = { try await auth.tokens().access }
        return (CloudOwnerAPIClient(baseURL: auth.configuration.ownerAPIBaseURL(), accessToken: access, teamID: { team }, buildSpace: auth.configuration.buildSpace), team)
    }

    /// `github.status`'s `state` and `repos_scope`: `ready`, `not_connected`, or `unavailable` (signed
    /// out, no App in this deployment, a team policy that disallows GitHub, or no answer).
    public func status() async -> (state: String, reposScope: String?) {
        guard let owner = owner() else { return ("unavailable", nil) }
        let (app, scope) = await owner.client.gitHubAppStatus(team: owner.team)
        switch app {
        case .ready: return ("ready", scope)
        case .notConnected: return ("not_connected", nil)
        case .notConfigured, .unknown: return ("unavailable", nil)
        }
    }

    /// `github.repos.list`.
    public func repos(query: String?) async -> Result<CloudGitHubRepos, CloudGitHubRepos.Failure> {
        guard let owner = owner() else { return .failure(.unavailable) }
        return await owner.client.gitHubRepos(team: owner.team, query: query)
    }
}
