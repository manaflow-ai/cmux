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
    private var loadedScope: Scope?
    private var workingScope: Scope?
    private var generation = 0
    @ObservationIgnored private var authorizations: [Scope: (id: String, url: URL, expires: Date)] = [:]
    private(set) var connections: [JSONValue] = []
    private(set) var configured = false
    private var errorScope: Scope?
    public var error: Bool { scope() != nil && errorScope == scope() }
    public var pending: Bool { currentConnections.contains { $0["status"]?.stringValue == "pending" } || scope().map { authorizations[$0] != nil } == true }

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
    public var canConnect: Bool { ready && !busy && !connected && (!pending || scope().map(resumable) == true) }

    /// A pending flow this launch can resume: its cached browser URL, or the idempotency key of a
    /// connect whose response was lost (replaying it returns the same pending connection's URL).
    private func resumable(_ bound: Scope) -> Bool { authorizations[bound] != nil || connectKeys[bound] != nil }

    /// An active connection's Reconfigure: its installation's page on GitHub, where the person changes the account's
    /// or org's repository access (another account or org: Disconnect, then Connect GitHub picks it).
    public func canReconfigure(_ row: JSONValue) -> Bool {
        scope() != nil && row["status"]?.stringValue == "active"
    }

    public func canDisconnect(_ row: JSONValue) -> Bool {
        scope() != nil && row["created_by"]?.stringValue == scope()?.user
    }

    /// One shared entry point for Settings, the Setup Guide, the palette and CLI.
    public func connect() async {
        let bound = scope()
        await perform("githubRefresh")
        guard scope() == bound, !error else { return }
        if connected { return }
        await perform("githubConnect")
    }

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
                // A pending flow from another launch has no resumable URL or key here.
                // Keep it pending until refresh or disconnect resolves that flow.
                guard ready, !connected, !pending || resumable(bound) else { return }
                if let authorization = authorizations[bound], authorization.expires <= now() {
                    authorizations[bound] = nil
                    connectKeys[bound] = nil
                }
                if let authorization = authorizations[bound] {
                    open(authorization.url)
                } else {
                    if connectKeys[bound] == nil { connectKeys[bound] = UUID().uuidString }
                    // An API from before the completion link refuses its params: the console finishes it. The retry has its
                    // own key, derived so its own retry is the same ask (the same key with other params is a conflict).
                    let value: JSONValue
                    do { value = try await call(bound, "integration.connect", connectParams(returning: true), connectKeys[bound]) } catch GitHubFailure.refused where completionLink != nil {
                        value = try await call(bound, "integration.connect", connectParams(returning: false), connectKeys[bound].map { $0 + ":plain" })
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
            connections = rows.filter { $0["provider"]?.stringValue == "github" && !["revoked", "expired"].contains($0["status"]?.stringValue ?? "") }
            configured = providers.contains { $0["provider"]?.stringValue == "github" && $0["configured"]?.boolValue == true }
            loadedScope = bound
            if let authorization = authorizations[bound],
               !connections.contains(where: { $0["id"]?.stringValue == authorization.id && $0["status"]?.stringValue == "pending" }) {
                authorizations[bound] = nil
                connectKeys[bound] = nil
            }
        } catch {
            if action == "githubConnect", generation == ticket, scope() == bound,
               let failure = error as? GitHubFailure, case .refused = failure {
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

    public enum GitHubFailure: Error { case changedAccount, invalidReply, refused }
}
