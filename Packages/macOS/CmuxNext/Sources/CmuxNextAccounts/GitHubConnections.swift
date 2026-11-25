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
    public var connected: Bool { currentConnections.contains { $0["status"]?.stringValue == "active" && (canDisconnect($0) || $0["sharing"]?.stringValue == "team") } }
    public var ready: Bool { scope() != nil && loadedScope == scope() && configured }
    public var canConnect: Bool { ready && !busy && !connected && (!pending || scope().map(resumable) == true) }

    /// A pending flow this launch can resume: its cached browser URL, or the idempotency key of a
    /// connect whose response was lost (replaying it returns the same pending connection's URL).
    private func resumable(_ bound: Scope) -> Bool { authorizations[bound] != nil || connectKeys[bound] != nil }

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
                    let value = try await call(bound, "integration.connect", ["provider": "github"], connectKeys[bound])
                    guard scope() == bound, generation == ticket else { return }
                    guard let raw = value["authorize_url"]?.stringValue, let url = Self.installationURL(raw),
                          let id = value["connection"]?["id"]?.stringValue, !id.isEmpty else { throw GitHubFailure.invalidReply }
                    authorizations[bound] = (id, url, Self.authorizationExpiration(url) ?? now())
                    open(url)
                }
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
    public nonisolated static func installationURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil,
              url.path.range(of: #"^/apps/[A-Za-z0-9-]+/installations/new$"#, options: .regularExpression) != nil else { return nil }
        return url
    }

    /// Expiry is only a cache hint; the API still verifies the signed state on completion.
    private nonisolated static func authorizationExpiration(_ url: URL) -> Date? {
        guard let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload), let value = try? JSONValue.parse(data), let expires = value["exp"]?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: expires)
    }

    /// The existing API identity contract (`domains/user.ts::stackTeamIdFor`).
    public nonisolated static func backendTeam(project: String, stackTeam: String?) -> String? {
        guard let stackTeam else { return nil }
        let team = UUID(uuidString: stackTeam) == nil ? stackTeam : stackTeam.lowercased()
        let digest = SHA256.hash(data: Data("stack-team:\(project):\(team)".utf8))
        return "team_" + digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    public nonisolated static func backendUser(project: String, stackUser: String) -> String {
        let digest = SHA256.hash(data: Data("stack:\(project):\(stackUser)".utf8))
        return "user_" + digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    public enum GitHubFailure: Error { case changedAccount, invalidReply, refused }
}
