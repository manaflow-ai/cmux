public import Foundation
import os

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
        /// The repository's size in GitHub's KB (`size_kb`), when the route gives it: a Cloud start in it sizes its machine.
        public var sizeKb: Int?

        public init(fullName: String, isPrivate: Bool, defaultBranch: String?, sizeKb: Int? = nil) {
            (self.fullName, self.isPrivate, self.defaultBranch, self.sizeKb) = (fullName, isPrivate, defaultBranch, sizeKb)
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
            let sizeKb = (row["size_kb"] as? NSNumber).flatMap { $0.int64Value >= 0 && $0.int64Value < Int64(Int32.max) ? Int($0.int64Value) : nil }
            return Repo(fullName: name, isPrivate: row["private"] as? Bool ?? true, defaultBranch: branch, sizeKb: sizeKb)
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
    /// `reauthDetail` is the server's reason a ``CloudGitHubApp/needsReauth`` connection gave, when it gave one.
    public func gitHubAppStatus(team: String) async -> (app: CloudGitHubApp, reposScope: String?, reauthDetail: String?) {
        guard let answer = await gitHubStatus(team: team) else { return (.unknown, nil, nil) }
        return (CloudGitHubApp(status: answer.status, body: answer.body), CloudGitHubApp.reposScope(status: answer.status, body: answer.body),
                CloudGitHubApp.reauthDetail(status: answer.status, body: answer.body))
    }

    /// Where Settings' Reconfigure opens for `team`'s ready GitHub connection (``CloudGitHubApp/reconfigureURL(status:body:)``);
    /// nil when it is not ready or the status route did not answer.
    public func gitHubReconfigureURL(team: String) async -> URL? {
        guard let answer = await gitHubStatus(team: team) else { return nil }
        return CloudGitHubApp.reconfigureURL(status: answer.status, body: answer.body)
    }

    /// `GET /v1/integrations/github/repos?team=&query=` with the person's own session (the daemon's `owner.github_repos`,
    /// rows read as ``CloudGitHubRepos/parse(status:body:)`` reads them).
    public func gitHubRepos(team: String, query: String?) async -> Result<CloudGitHubRepos, CloudGitHubRepos.Failure> {
        guard CloudGitHubApp.path(team: team) != nil else { return .failure(.unavailable) }
        var args: [String: any Sendable] = ["team": team]
        if let text = query?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256), !text.isEmpty { args["query"] = String(text) }
        do {
            return CloudGitHubRepos.parse(status: 200, body: try await daemon("owner.github_repos", args, timeout: Self.personWait))
        } catch CloudAPIError.http(_, let code?, _, _, _) where code == "github.not_connected" || code == "needs_reauth" {
            return .failure(.notConnected)
        } catch {
            return .failure(.unavailable)
        }
    }

    /// `integration.connect {provider: "github"}` on `/v1/ops`, as the person, in ``teamID``'s team (`x-cmux-team`), under
    /// `key`: a replay of the key answers the same pending connection and page.
    /// `returnTo` is the app's completion link (``CloudGitHubCompletion/link(scheme:)``): GitHub's redirect comes back
    /// to this app, which finishes the connection with its own sign-in (#46018).
    /// `repo` (`owner/name`, a Cloud start's Connect GitHub card): the API reuses an active connection that already covers
    /// it (``CloudGitHubConnects/Answer/connected``), and for an owner the App is installed on already it answers GitHub's
    /// authorize page instead of the install page, so the person only approves and comes straight back (#55104).
    public func gitHubConnect(key: String, returnTo: String? = nil, repo: String? = nil) async -> CloudGitHubConnects.Answer {
        var args: [String: any Sendable] = ["idempotencyKey": key]
        if let returnTo { args["returnTo"] = returnTo }
        if let repo { args["repo"] = repo }
        let failure: CloudAPIError
        do {
            if let answer = CloudGitHubConnects.reply(try await daemon("owner.github_connect", args, timeout: Self.personWait)) { return answer }
            failure = .decoding("cloud.owner.github_connect: no install page")
        } catch {
            failure = error as? CloudAPIError ?? .decoding("cloud.owner.github_connect")
        }
        let answer = CloudGitHubConnects.answer(failure)
        // Why it opened nothing: the HTTP status and the API's error code (no tokens, no page).
        if case .http(let status, let code, _, _, _) = failure {
            CloudGitHubConnects.logger.notice("github connect: HTTP \(status, privacy: .public) error \(code ?? "-", privacy: .public) return link \(returnTo != nil, privacy: .public)")
        } else {
            CloudGitHubConnects.logger.notice("github connect: no answer (return link \(returnTo != nil, privacy: .public))")
        }
        return answer
    }

    /// `integration.list` on `/v1/read` in ``teamID``'s team: whether a GitHub connection this person sees is pending
    /// (Settings' Connect, or another launch's); nil when it did not answer.
    public func gitHubConnectPending() async -> Bool? {
        guard let data = try? await daemon("owner.github_list", [:], timeout: Self.bound(Self.personWait)),
              let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return reply["pending"] as? Bool
    }

    /// The status route's status and body for `team` (the daemon's `owner.github_app`, `raw`); nil when it did not
    /// answer, or for a team that is not a `team_…` id.
    func gitHubStatus(team: String) async -> (status: Int, body: Data)? {
        guard CloudGitHubApp.path(team: team) != nil,
              let data = try? await daemon("owner.github_app", ["team": team, "raw": true], timeout: Self.bound(Self.personWait)),
              let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let status = reply["status"] as? Int else { return nil }
        let body = reply["body"].flatMap { $0 is NSNull ? nil : (try? JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed)) }
        return (status, body ?? Data())
    }

    /// How long one of the person's GitHub calls waits, as before (a slower answer is no answer).
    static let personWait: Duration = .seconds(15)
}

/// Each team's Connect GitHub from the picker this launch, as Settings' Connect GitHub keeps its own: the installation
/// page `integration.connect` answered, opened again until its signed state expires, and the idempotency key that
/// asked, kept while its answer may have been lost. A second click never adds another pending connection.
@MainActor
public final class CloudGitHubConnects {
    /// What one `integration.connect` answered.
    public enum Answer: Equatable, Sendable {
        case page(URL)
        /// An active connection already covers the asked repository (`{connected: true}`): nothing to open (#55104).
        case connected
        /// A definitive refusal or a reply this client will not use: the next click asks with a new key.
        case refused
        /// No answer, a timeout, throttling or a server failure: the connect may have happened, so the key stays.
        case noAnswer
    }

    nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.github")
    private var flows: [String: (key: String, page: URL?)] = [:]
    /// The completions count (``CloudGitHubChanges/count``) the pages were asked under: a newer one spends them.
    var seenChanges = 0
    private let newKey: () -> String

    public init(newKey: @escaping () -> String = { UUID().uuidString }) { self.newKey = newKey }

    /// A completion finished (``CloudGitHubChanges/count`` moved): every page asked before is spent, since its state names
    /// a connection that is no longer pending. The next click asks again, so a repository the link still left out gets
    /// a fresh page instead of the used one (#55104).
    public func forgetPages() { flows = [:] }

    /// The page to open for `team` at `now`: the one asked before while it holds, else what `ask(key)` answers.
    public func page(team: String, now: Date, ask: (String) async -> Answer) async -> URL? {
        if case .page(let url) = await answer(team: team, now: now, ask: ask) { return url }
        return nil
    }

    /// ``page(team:now:ask:)`` for one repository's Connect (`repo`, nil for none), which may also answer
    /// ``Answer/connected``. Each repository keeps its own flow: a card for one never replays another's page.
    public func answer(team: String, repo: String? = nil, now: Date, ask: (String) async -> Answer) async -> Answer {
        let flow = repo.map { "\(team) \($0.lowercased())" } ?? team
        if let page = flows[flow]?.page {
            if let expires = CloudGitHubApp.authorizationExpiry(page), expires > now { return .page(page) }
            flows[flow] = nil
        }
        let key = flows[flow]?.key ?? newKey()
        flows[flow] = (key, nil)
        let answer = await ask(key)
        guard flows[flow]?.key == key else { // another click asked meanwhile
            switch answer { case .page, .connected: return answer; case .refused, .noAnswer: return .noAnswer }
        }
        switch answer {
        case .page(let url): flows[flow] = (key, url)
        case .refused, .connected: flows[flow] = nil
        case .noAnswer: break
        }
        return answer
    }

    /// The daemon's `owner.github_connect` answer: `{connected: true, connection}` (an active connection already covers the
    /// repository: nothing to open) or `{authorize_url, connection}` with a page ``CloudGitHubApp/installationURL(_:)``
    /// allows; nil for anything else (a settings page carries no state, so it is never a connect page).
    nonisolated static func reply(_ answer: Data) -> Answer? {
        guard let reply = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any],
              let id = reply["connection"] as? String, !id.isEmpty else { return nil }
        if reply["connected"] as? Bool == true { return .connected }
        guard let raw = reply["authorize_url"] as? String, let url = CloudGitHubApp.installationURL(raw) else { return nil }
        return .page(url)
    }

    /// A connect that gave no page: a 408, 429 or 5xx, a timeout, no cmux or no sign-in may have run (the key stays);
    /// any other refusal, or a reply this client will not use, is refused.
    nonisolated static func answer(_ failure: CloudAPIError) -> Answer {
        switch failure {
        case .http(let status, _, _, _, _): status >= 500 || status == 408 || status == 429 ? .noAnswer : .refused
        case .timedOut, .transport, .notSignedIn, .noBackend: .noAnswer
        default: .refused
        }
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
        return (CloudOwnerAPIClient(baseURL: auth.configuration.ownerAPIBaseURL(), accessToken: access, teamID: { team }, buildSpace: auth.configuration.buildSpace, machineIO: auth.machineIO), team)
    }

    /// `github.status`: ready, not connected, or unavailable and why.
    public func status() async -> Status {
        // A saved sign-in still being restored is not signed out: no sign-in to start for it.
        guard auth.isSignedIn else { return .unavailable(auth.isRestoring ? .unreachable : .signedOut) }
        guard let owner = await owner() else { return .unavailable(.unreachable) }
        let (app, scope, detail) = await owner.client.gitHubAppStatus(team: owner.team)
        let status = Status(app, reposScope: scope, reauthDetail: detail)
        // A completion the API refused is the last word on a team that is still not connected: say so where Connect is.
        if case .notConnected = status, let refusal = auth.gitHubChanges.refusal { return .linkRefused(reason: refusal.reason) }
        // An organization's owners were asked to install the App: say so until it is approved (the status turns ready).
        if case .requested(let asked) = auth.gitHubChanges.phase, status == .notConnected || status == .linking { return .requested(owner: asked) }
        return status
    }

    /// `github.status`'s `state`, `repos_scope` and, when unavailable, its `reason`. Every case but `ready` and
    /// `unavailable` is a state with a Connect GitHub: the wire `state` stays `not_connected`, and ``problem`` and the
    /// page's words (`AgentPaneGitHubRequest.statusReply`) say which.
    public enum Status: Equatable, Sendable {
        case ready(reposScope: String?)
        case notConnected
        /// Linked, but GitHub no longer honors it (suspended or uninstalled); `detail` is the server's reason, if any.
        case needsReauth(detail: String?)
        /// A link is under way: the person has not finished on GitHub.
        case linking
        /// The connection is in the server's `error` state.
        case error
        /// The last completion the API refused (an expired state, a non-owner's request); `reason` is the API's, if any.
        case linkRefused(reason: String?)
        /// The person asked an organization's owners to install the App (GitHub's `setup_action=request`); `owner` is the
        /// organization when known. Connected once an owner approves.
        case requested(owner: String?)
        case unavailable(Unavailable)

        /// The status route's answer for a signed-in person.
        public init(_ app: CloudGitHubApp, reposScope: String?, reauthDetail: String? = nil) {
            switch app {
            case .ready: self = .ready(reposScope: reposScope)
            case .notConnected: self = .notConnected
            case .needsReauth: self = .needsReauth(detail: reauthDetail)
            case .linking: self = .linking
            case .error: self = .error
            case .notConfigured: self = .unavailable(.notConfigured)
            case .unknown: self = .unavailable(.unreachable)
            }
        }

        /// `ready`, `not_connected` or `unavailable`: the folder menu's three, which every Connect state shares.
        public var state: String {
            switch self {
            case .ready: "ready"
            case .notConnected, .needsReauth, .linking, .error, .linkRefused, .requested: "not_connected"
            case .unavailable: "unavailable"
            }
        }

        /// Which kind of not connected: `needs_reauth`, `linking`, `error` or `link_refused`; nil for any other state.
        public var problem: String? {
            switch self {
            case .needsReauth: "needs_reauth"
            case .linking: "linking"
            case .error: "error"
            case .linkRefused: "link_refused"
            case .requested: "requested"
            case .ready, .notConnected, .unavailable: nil
            }
        }

        /// `all` or `selected` when ready; nil otherwise.
        public var reposScope: String? {
            if case .ready(let scope) = self { return scope }
            return nil
        }

        /// Why it is unavailable; nil otherwise.
        public var reason: Unavailable? {
            if case .unavailable(let reason) = self { return reason }
            return nil
        }
    }

    /// Why GitHub is unavailable here (`github.status`'s `reason`).
    public enum Unavailable: String, Equatable, Sendable {
        /// No cmux account is signed in.
        case signedOut = "signed_out"
        /// This deployment has no cmux GitHub App.
        case notConfigured = "not_configured"
        /// No answer, or a team policy that disallows GitHub.
        case unreachable
    }

    /// `github.repos.list`.
    public func repos(query: String?) async -> Result<CloudGitHubRepos, CloudGitHubRepos.Failure> {
        guard let owner = await owner() else { return .failure(.unavailable) }
        return await owner.client.gitHubRepos(team: owner.team, query: query)
    }

    /// What the status route alone settles for `github.connect`; nil when the team has no connection (ask `integration.connect`).
    /// A connected team opens its installation settings, or, when the status names none (an older Worker, or one whose
    /// GitHub lookup failed), opens nothing: `integration.connect` would add a second connection for the same installation.
    /// With `repo` only what makes a connect impossible settles it (no App here, no answer): the API decides the rest.
    nonisolated static func connectFromStatus(status: Int, body: Data, repo: String? = nil) -> Connect? {
        if let repo {
            switch CloudGitHubApp(status: status, body: body) {
            case .notConfigured: return .unavailable(.notConfigured)
            case .unknown: return .unavailable(.unreachable)
            // A suspended install on the repository's owner is fixed on its settings page, as without a repository:
            // a new link through GitHub's authorize page would not lift the suspension.
            case .needsReauth:
                guard let page = CloudGitHubApp.configureURL(status: status, body: body),
                      Self.settingsPage(page, isFor: repo) else { return nil }
                return .open(page)
            default: return nil
            }
        }
        return switch CloudGitHubApp(status: status, body: body) {
        case .ready: CloudGitHubApp.configureURL(status: status, body: body).map(Connect.open) ?? .connected
        // A suspended install is fixed on its settings page; with none named (or uninstalled) Connect is the fix.
        case .needsReauth: CloudGitHubApp.configureURL(status: status, body: body).map(Connect.open)
        case .linking, .notConnected, .error: nil
        case .notConfigured: .unavailable(.notConfigured)
        case .unknown: .unavailable(.unreachable)
        }
    }

    /// Whether `page` (an installation's settings page) belongs to `repo`'s owner: an organization's page names it
    /// (`/organizations/<owner>/…`); a personal account's page names no account, so it is never taken as the owner's.
    nonisolated static func settingsPage(_ page: URL, isFor repo: String) -> Bool {
        let owner = repo.split(separator: "/").first.map { $0.lowercased() } ?? ""
        let parts = page.path.split(separator: "/")
        return parts.count >= 2 && parts[0] == "organizations" && parts[1].lowercased() == owner
    }

    /// What `github.connect` does.
    public enum Connect: Equatable, Sendable {
        /// Open this page in the person's browser.
        case open(URL)
        /// The team is connected already: nothing to open.
        case connected
        /// Signed out, no App here, a team policy that disallows GitHub, or no answer from the status route.
        case unavailable(Unavailable)
        /// The team has no connection and `integration.connect` gave no page.
        case failed
    }

    /// `github.connect` for the team ``owner()`` names (Settings' Connect GitHub asks in the active team, which can be
    /// another one): a connected team's installation settings, where the person adds repositories (More repositories);
    /// a team with no connection, the App's installation page from `integration.connect` in that team.
    ///
    /// `repo` (`owner/name`): a Cloud start's Connect GitHub card for the repository its machine could not clone. The
    /// team's status says nothing of that repository (a connection on the person's own account is `ready`, and its
    /// settings page can never add an organization's repository, nor does GitHub's save there carry a state to finish
    /// anything with), so the API is asked for it: an active connection that covers it answers ``Connect/connected``,
    /// and an owner with the App installed answers GitHub's authorize page, whose redirect the app finishes (#55104).
    ///
    /// `addAccount`: the picker's Add organization. A connected team gets GitHub's install page too (its account chooser
    /// lists the organizations the App is not on yet), as a new connection beside the first, instead of the first one's
    /// settings page.
    public func connect(repo: String? = nil, addAccount: Bool = false) async -> Connect {
        // A saved sign-in still being restored is not signed out: no sign-in to start for it.
        guard auth.isSignedIn else { return .unavailable(auth.isRestoring ? .unreachable : .signedOut) }
        auth.gitHubChanges.forgetRefusal() // a new Connect starts over: the last refused link no longer applies
        guard let owner = await owner(), let status = await owner.client.gitHubStatus(team: owner.team) else { return .unavailable(.unreachable) }
        if !addAccount || repo != nil, let known = Self.connectFromStatus(status: status.status, body: status.body, repo: repo) { return known }
        let client = owner.client
        if auth.gitHubChanges.count != connects.seenChanges { connects.forgetPages(); connects.seenChanges = auth.gitHubChanges.count }
        if let repo {
            let returnTo = CloudGitHubCompletion.link(scheme: auth.configuration.callbackScheme)
            switch await connects.answer(team: owner.team, repo: repo, now: Date(), ask: { key in
                await client.gitHubConnect(key: key, returnTo: returnTo, repo: repo)
            }) {
            case .page(let page): return .open(page)
            case .connected: return .connected
            case .refused, .noAnswer: return .failed
            }
        }
        // A pending connection never blocks a click (#46018): one this launch can't resume (another launch's, or one
        // whose return failed) can't be finished, and it expires on its own; the API adds a new one beside it.
        let returnTo = CloudGitHubCompletion.link(scheme: auth.configuration.callbackScheme)
        // An API from before the completion link refuses its params (`validation.invalid`): ask again without it, and the
        // console finishes the connection as before. Under its own key, derived so a retry of it is the same ask: the API
        // keeps the first key, and the same key with other params is an `idempotency.conflict`.
        guard let page = await connects.page(team: owner.team, now: Date(), ask: { key in
            let answer = await client.gitHubConnect(key: key, returnTo: returnTo)
            guard case .refused = answer else { return answer }
            return await client.gitHubConnect(key: key + ":plain")
        }) else { return .failed }
        return .open(page)
    }
}
