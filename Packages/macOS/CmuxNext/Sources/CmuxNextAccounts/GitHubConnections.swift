import CmuxNextCloud
public import CmuxNextSettings
import CryptoKit
public import Foundation
import Observation

/// The GitHub App connection for the account and team selected in Settings.
/// Calls the existing owner API as the person; never widens the app credential relay.
@MainActor @Observable
public final class GitHubConnections {
    public struct Scope: Hashable, Sendable {
        public let user: String
        public let team: String?
        public init(user: String, team: String?) { self.user = user; self.team = team }
    }
    public typealias Call = @MainActor (Scope, String, JSONValue, String?) async throws -> JSONValue
    @ObservationIgnored private let scope: () -> Scope?
    @ObservationIgnored private let call: Call
    @ObservationIgnored private let open: (URL) -> Void
    /// Where Reconfigure opens for the scope's connected installation (its installation settings on GitHub), nil when
    /// none is known. The live model sets it (``live(auth:ownerAPI:preview:)``); unset, Reconfigure reports a failure.
    @ObservationIgnored public var reconfigurePage: (@MainActor (Scope) async -> URL?)?
    /// The link a connect asks GitHub's redirect to come back to: this app's `<scheme>://integration/complete`, where
    /// the app finishes the connection with its own sign-in (#46018). The live model sets it; unset, a connect asks none.
    @ObservationIgnored public var completionLink: String?
    /// The live model's watch of ``CloudGitHubChanges`` (a finished install re-reads the connections).
    @ObservationIgnored public var changes: Task<Void, Never>? { didSet { oldValue?.cancel() } }
    /// The words for the last completion the API refused (an expired link, a non-owner's request), shown where Connect
    /// GitHub is until the next Connect starts over or a connection takes. The live model sets it from
    /// ``CloudGitHubChanges/refusal`` (``refusalWords(reason:)``); nil when nothing was refused.
    public var linkRefusal: String?
    @ObservationIgnored private let now: () -> Date
    /// One connect ask: the scope, and the repository a chat's Connect GitHub card named (nil for
    /// Settings, the palette and the CLI). Each ask keeps its own idempotency key and browser URL,
    /// so a card for one repository never replays another's answer.
    struct Ask: Hashable {
        let scope: Scope
        let repo: String?
    }
    @ObservationIgnored private var connectKeys: [Ask: String] = [:]
    private var loadedScope: Scope?
    private var workingScope: Scope?
    private var generation = 0
    @ObservationIgnored private var authorizations: [Ask: (id: String, url: URL, expires: Date)] = [:]
    private(set) var connections: [JSONValue] = []
    private(set) var configured = false
    private var errorScope: Scope?
    public var error: Bool { scope() != nil && errorScope == scope() }
    public var pending: Bool { currentConnections.contains { $0["status"]?.stringValue == "pending" } || scope().map { bound in authorizations.keys.contains { $0.scope == bound } } == true }

    public init(scope: @escaping () -> Scope?, call: @escaping Call, open: @escaping (URL) -> Void, now: @escaping () -> Date = Date.init) {
        self.scope = scope
        self.call = call
        self.open = open
        self.now = now
    }

    public var scopeIsSignedOut: Bool { scope() == nil }
    public var busy: Bool { workingScope != nil && workingScope == scope() }
    public var currentConnections: [JSONValue] { loadedScope == scope() ? connections : [] }
    /// `integration.connect`'s params: GitHub, the card's repository, and the app's completion link when one is set
    /// (``completionLink``: the app finishes the connect, and the chat's card goes on when the person comes back), else
    /// the chat's own link (`returnTo`).
    func connectParams(returning: Bool, repo: String? = nil, returnTo: String? = nil) -> JSONValue {
        var params: [String: JSONValue] = ["provider": "github"]
        if let repo { params["repo"] = .string(repo) }
        if returning, let link = completionLink ?? returnTo { params["return_to"] = .string(link) }
        return .object(params)
    }
    public var connected: Bool { currentConnections.contains { $0["status"]?.stringValue == "active" && (canDisconnect($0) || $0["sharing"]?.stringValue == "team") } }
    public var ready: Bool { scope() != nil && loadedScope == scope() && configured }
    /// A pending connection never blocks Connect (#46018): this launch resumes its own flow (its cached URL, or the key
    /// of a connect whose answer was lost); one it can't resume (another launch's, or one whose return to cmux failed)
    /// can't be finished, so Connect asks for a new one and the stale one expires on its own (30 min).
    public var canConnect: Bool { ready && !busy && !connected }

    /// An active connection's Reconfigure: its installation's page on GitHub, where the person changes the account's
    /// or org's repository access (another account or org: Disconnect, then Connect GitHub picks it).
    public func canReconfigure(_ row: JSONValue) -> Bool {
        scope() != nil && row["status"]?.stringValue == "active"
    }

    public func canDisconnect(_ row: JSONValue) -> Bool {
        scope() != nil && row["created_by"]?.stringValue == scope()?.user
    }

    /// One shared entry point for Settings, the Setup Guide, the palette, the CLI and a chat's
    /// Connect GitHub card. Without `repo`, an active connection is done. With one (the card's
    /// failed call), the API decides: a connection that covers it answers connected and nothing
    /// opens; otherwise GitHub's page for that repository's owner opens. `returnTo`, a cmux link
    /// to the chat, rides in the API's signed state and GitHub's return opens it.
    public func connect(repo: String? = nil, returnTo: String? = nil) async {
        let bound = scope()
        await perform("githubRefresh")
        guard scope() == bound, !error else { return }
        if connected, repo == nil { return }
        await perform("githubConnect", repo: repo, returnTo: returnTo)
    }

    public func perform(_ action: String, connection: String? = nil, repo: String? = nil, returnTo: String? = nil) async {
        guard let bound = scope(), workingScope != bound else { return }
        generation += 1
        let ticket = generation
        workingScope = bound
        errorScope = nil
        defer { if generation == ticket { workingScope = nil } }
        do {
            switch action {
            case "githubConnect":
                linkRefusal = nil // a new Connect starts over
                // A pending connection never blocks Connect (#46018): one this launch can't resume asks for a new
                // one. A card's ask (a repository) goes to the API whatever the list says: the API knows what covers it.
                let ask = Ask(scope: bound, repo: repo)
                guard ready, repo != nil || !connected else { return }
                if let authorization = authorizations[ask], authorization.expires <= now() {
                    authorizations[ask] = nil
                    connectKeys[ask] = nil
                }
                if let authorization = authorizations[ask] {
                    open(authorization.url)
                } else {
                    if connectKeys[ask] == nil { connectKeys[ask] = UUID().uuidString }
                    // An API from before the completion link refuses its params: the console finishes it. The retry has its
                    // own key, derived so its own retry is the same ask (the same key with other params is a conflict).
                    let value: JSONValue
                    do { value = try await call(bound, "integration.connect", connectParams(returning: true, repo: repo, returnTo: returnTo), connectKeys[ask]) } catch GitHubFailure.refused where completionLink != nil || returnTo != nil {
                        value = try await call(bound, "integration.connect", connectParams(returning: false, repo: repo, returnTo: nil), connectKeys[ask].map { $0 + ":plain" })
                    }
                    guard scope() == bound, generation == ticket else { return }
                    guard let id = value["connection"]?["id"]?.stringValue, !id.isEmpty else { throw GitHubFailure.invalidReply }
                    if value["connected"]?.boolValue == true {
                        // Already covered: nothing to open; the list below shows it.
                        connectKeys[ask] = nil
                    } else {
                        guard let raw = value["authorize_url"]?.stringValue, let url = Self.installationURL(raw) else { throw GitHubFailure.invalidReply }
                        authorizations[ask] = (id, url, Self.authorizationExpiration(url) ?? now())
                        open(url)
                    }
                }
            case "githubReconfigure":
                guard let connection, currentConnections.contains(where: { $0["id"]?.stringValue == connection && canReconfigure($0) }) else { return }
                guard let page = await reconfigurePage?(bound) else { throw GitHubFailure.invalidReply }
                guard scope() == bound, generation == ticket else { return }
                open(page)
            case "githubDisconnect":
                guard let connection, currentConnections.contains(where: { $0["id"]?.stringValue == connection && canDisconnect($0) }) else { return }
                _ = try await call(bound, "integration.revoke", ["connection": .string(connection)], UUID().uuidString)
            default: break
            }
            // The same list after every gesture, and on Settings focus. No polling loop.
            let value = try await call(bound, "integration.list", [:], nil)
            guard scope() == bound, generation == ticket else { return }
            guard let rows = value["connections"]?.arrayValue, let providers = value["providers"]?.arrayValue else {
                throw GitHubFailure.invalidReply
            }
            connections = rows.filter { $0["provider"]?.stringValue == "github" && !["revoked", "expired"].contains($0["status"]?.stringValue ?? "") }
            configured = providers.contains { $0["provider"]?.stringValue == "github" && $0["configured"]?.boolValue == true }
            loadedScope = bound
            for (ask, authorization) in authorizations where ask.scope == bound
                && !connections.contains(where: { $0["id"]?.stringValue == authorization.id && $0["status"]?.stringValue == "pending" }) {
                authorizations[ask] = nil
                connectKeys[ask] = nil
            }
        } catch {
            if action == "githubConnect", generation == ticket, scope() == bound,
               let failure = error as? GitHubFailure, case .refused = failure {
                // A definitive API refusal is replayed under its mutation key.
                // Transport failures keep the key because the mutation may have succeeded.
                connectKeys[Ask(scope: bound, repo: repo)] = nil
            }
            if scope() == bound, generation == ticket { errorScope = bound }
        }
    }

    /// Only the GitHub pages integration.connect answers may open: the App's installation page,
    /// its installation page for one owner (`installations/new/permissions?target_id=…`), and
    /// GitHub's OAuth authorize page (an installation that already covers the owner). https on
    /// github.com itself, with no user, password or port.
    public nonisolated static func installationURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil,
              Self.connectPaths.contains(where: { url.path.range(of: $0, options: .regularExpression) != nil }) else { return nil }
        return url
    }

    /// The paths of the pages ``installationURL(_:)`` lets open.
    nonisolated static let connectPaths = [
        #"^/apps/[A-Za-z0-9-]+/installations/new$"#,
        #"^/apps/[A-Za-z0-9-]+/installations/new/permissions$"#,
        #"^/login/oauth/authorize$"#,
    ]

    /// Expiry is only a cache hint; the API still verifies the signed state on completion.
    private nonisolated static func authorizationExpiration(_ url: URL) -> Date? { CloudGitHubApp.authorizationExpiry(url) }

    /// The existing API identity contract (`domains/user.ts::stackTeamIdFor`).
    public nonisolated static func backendTeam(project: String, stackTeam: String?) -> String? {
        guard let stackTeam else { return nil }
        let team = UUID(uuidString: stackTeam) == nil ? stackTeam : stackTeam.lowercased()
        let digest = SHA256.hash(data: Data("stack-team:\(project):\(team)".utf8))
        return "team_" + digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    /// The person's personal team (`domains/user.ts::personalTeamIdFor`): a scope with no Stack team acts in it.
    public nonisolated static func personalTeam(user: String) -> String {
        let digest = SHA256.hash(data: Data("personal:\(user)".utf8))
        return "team_" + digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    public nonisolated static func backendUser(project: String, stackUser: String) -> String {
        let digest = SHA256.hash(data: Data("stack:\(project):\(stackUser)".utf8))
        return "user_" + digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    public enum GitHubFailure: Error { case changedAccount, invalidReply, refused }
}
