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
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var connectKeys: [Scope: String] = [:]
    /// The API refused the completion link this launch (an API from before it): later connects ask without it.
    @ObservationIgnored private var returnLinkRefused = false
    /// When the scope's list was last read: a Connect right after (Settings read it on focus) uses it as it is.
    @ObservationIgnored private var loadedAt: Date?
    private var loadedScope: Scope?
    private var workingScope: Scope?
    /// The scope whose Connect is asking for GitHub's page now: the button says so until the page opens.
    private var connectingScope: Scope?
    private var generation = 0
    @ObservationIgnored private var authorizations: [Scope: (id: String, url: URL, expires: Date)] = [:]
    private(set) var connections: [JSONValue] = []
    private(set) var configured = false
    private var errorScope: Scope?
    public var error: Bool { scope() != nil && errorScope == scope() }
    /// A connect is waiting on the person in GitHub: this launch's own page, or a pending connection younger than its
    /// lifetime (another launch's, Settings' elsewhere, an org owner's approval). It never holds Connect: a click opens
    /// this launch's page, or asks for a fresh one (hq#13939).
    public var pending: Bool {
        currentConnections.contains { $0["status"]?.stringValue == "pending" } || scope().map { authorizations[$0] != nil } == true
    }
    /// Connect is asking for GitHub's page right now.
    public var connecting: Bool { connectingScope != nil && connectingScope == scope() }

    public init(scope: @escaping () -> Scope?, call: @escaping Call, open: @escaping (URL) -> Void, now: @escaping () -> Date = Date.init) {
        self.scope = scope
        self.call = call
        self.open = open
        self.now = now
    }

    public var scopeIsSignedOut: Bool { scope() == nil }
    public var busy: Bool { workingScope != nil && workingScope == scope() }
    public var currentConnections: [JSONValue] { loadedScope == scope() ? connections : [] }
    /// `integration.connect`'s params: GitHub, and the app's completion link when one is set (``completionLink``).
    func connectParams(returning: Bool) -> JSONValue {
        var params: [String: JSONValue] = ["provider": "github"]
        if returning, let completionLink { params["return_to"] = .string(completionLink) }
        return .object(params)
    }
    public var connected: Bool { currentConnections.contains { $0["status"]?.stringValue == "active" && (canDisconnect($0) || $0["sharing"]?.stringValue == "team") } }
    public var ready: Bool { scope() != nil && loadedScope == scope() && configured }
    public var canConnect: Bool { ready && !busy && !connected }

    /// How long a pending connection waits for its install before the API expires it (`PENDING_CONNECTION_TTL_MS`).
    public static let pendingLifetime: TimeInterval = 30 * 60

    /// A pending row past ``pendingLifetime``: its install was cancelled or abandoned, and the API expires it.
    func isStalePending(_ row: JSONValue) -> Bool {
        guard row["status"]?.stringValue == "pending", let created = row["created_at"]?.doubleValue else { return false }
        return now().timeIntervalSince1970 - created / 1000 >= Self.pendingLifetime
    }

    /// An active connection's Reconfigure: its installation's page on GitHub, where the person changes the account's
    /// or org's repository access (another account or org: Disconnect, then Connect GitHub picks it).
    public func canReconfigure(_ row: JSONValue) -> Bool {
        scope() != nil && row["status"]?.stringValue == "active"
    }

    public func canDisconnect(_ row: JSONValue) -> Bool {
        scope() != nil && row["created_by"]?.stringValue == scope()?.user
    }

    /// One shared entry point for Settings, the Setup Guide, the palette and CLI.
    /// The list read moments before (Settings reads it on focus) stands in for a refresh, so a click asks GitHub's page at once.
    public func connect() async {
        let bound = scope()
        // The button says Opening GitHub… from the click, through the refresh, until the page opens.
        connectingScope = bound
        defer { if connectingScope == bound { connectingScope = nil } }
        let fresh = bound != nil && loadedScope == bound && loadedAt.map { now().timeIntervalSince($0) < Self.listReuse } == true
        if !fresh {
            await perform("githubRefresh")
            guard scope() == bound, !error else { return }
        }
        if connected { return }
        await perform("githubConnect")
    }

    /// How long a read list stands in for Connect's own refresh.
    static let listReuse: TimeInterval = 30

    public func perform(_ action: String, connection: String? = nil) async {
        guard let bound = scope(), workingScope != bound else { return }
        generation += 1
        let ticket = generation
        workingScope = bound
        errorScope = nil
        defer { if generation == ticket { workingScope = nil } }
        do {
            switch action {
            case "githubConnect":
                // A pending connection with no page here (a cancelled install, another launch's) never holds the click:
                // without this launch's page or key the connect asks for a fresh page; the API expires the old one.
                guard ready, !connected else { return }
                if let authorization = authorizations[bound], authorization.expires <= now() {
                    authorizations[bound] = nil
                    connectKeys[bound] = nil
                }
                if let authorization = authorizations[bound] {
                    open(authorization.url)
                } else {
                    if connectKeys[bound] == nil { connectKeys[bound] = UUID().uuidString }
                    connectingScope = bound
                    defer { if connectingScope == bound { connectingScope = nil } }
                    // An API from before the completion link refuses its params (`validation.invalid`, and only that): the
                    // console finishes it, and this launch's later connects ask without the link. The retry has its own key,
                    // derived so its own retry is the same ask (the same key with other params is a conflict).
                    let value: JSONValue
                    if returnLinkRefused || completionLink == nil {
                        value = try await call(bound, "integration.connect", connectParams(returning: false), connectKeys[bound].map { completionLink == nil ? $0 : $0 + ":plain" })
                    } else {
                        do { value = try await call(bound, "integration.connect", connectParams(returning: true), connectKeys[bound]) } catch GitHubFailure.invalidParams {
                            returnLinkRefused = true
                            value = try await call(bound, "integration.connect", connectParams(returning: false), connectKeys[bound].map { $0 + ":plain" })
                        }
                    }
                    guard scope() == bound, generation == ticket else { return }
                    guard let raw = value["authorize_url"]?.stringValue, let url = Self.installationURL(raw),
                          let id = value["connection"]?["id"]?.stringValue, !id.isEmpty else { throw GitHubFailure.invalidReply }
                    authorizations[bound] = (id, url, Self.authorizationExpiration(url) ?? now())
                    open(url)
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
            // A pending row past its lifetime (a cancelled install) is not shown: the API expires it.
            let listed = rows.filter {
                $0["provider"]?.stringValue == "github" && !["revoked", "expired"].contains($0["status"]?.stringValue ?? "") && !isStalePending($0)
            }
            // A reconnect makes a new connection: the old one that needed it (`needs_reauth`, `error`) stays in the API's
            // list beside the new active one for the same account. It is not shown, so it never asks to reconnect again.
            let activeAccounts = Set(listed.compactMap { $0["status"]?.stringValue == "active" ? $0["account"]?["key"]?.stringValue : nil })
            connections = listed.filter { row in
                guard ["needs_reauth", "error"].contains(row["status"]?.stringValue ?? ""), let key = row["account"]?["key"]?.stringValue else { return true }
                return !activeAccounts.contains(key)
            }
            configured = providers.contains { $0["provider"]?.stringValue == "github" && $0["configured"]?.boolValue == true }
            loadedScope = bound
            loadedAt = now()
            if let authorization = authorizations[bound],
               !connections.contains(where: { $0["id"]?.stringValue == authorization.id && $0["status"]?.stringValue == "pending" }) {
                authorizations[bound] = nil
                connectKeys[bound] = nil
            }
        } catch {
            if action == "githubConnect", generation == ticket, scope() == bound,
               let failure = error as? GitHubFailure, failure == .refused || failure == .invalidParams {
                // A definitive API refusal is replayed under its mutation key.
                // Transport failures keep the key because the mutation may have succeeded.
                connectKeys[bound] = nil
            }
            if scope() == bound, generation == ticket { errorScope = bound }
        }
    }

    /// Only the App installation page returned by integration.connect may open.
    public nonisolated static func installationURL(_ raw: String) -> URL? { CloudGitHubApp.installationURL(raw) }

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

    /// `invalidParams`: the API refused the params (`validation.invalid`); `refused`: any other definitive refusal.
    public enum GitHubFailure: Error { case changedAccount, invalidReply, refused, invalidParams }
}
