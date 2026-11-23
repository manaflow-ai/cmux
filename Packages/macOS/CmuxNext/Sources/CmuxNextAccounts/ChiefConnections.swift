public import CmuxNextCloud
import CmuxNextPages
public import CmuxNextSettings
public import Foundation
import Observation

/// The Chief's Google connections, Gmail and Google Calendar (cmux issue 34263), for the account
/// and team selected in Settings. Each is the backend's `Connection` of that provider
/// (`integration.list`, `integration.connect`, `integration.revoke`): the gateway holds the token,
/// this Mac never sees one, and the Chief and its agents call `mail.*` and `calendar.*` through it.
/// The list loads when the Chief card opens and after every gesture; nothing polls.
@MainActor @Observable
public final class ChiefConnections {
    public enum Provider: String, CaseIterable, Sendable {
        case gmail
        case googleCalendar = "google_calendar"
    }

    /// What a provider's row shows.
    public enum State: Equatable, Sendable {
        /// No cmux sign-in (or a managed team other than the selected one).
        case signedOut
        /// The list has not loaded yet, or this deployment cannot connect the provider.
        case unavailable
        case notConnected
        /// Approval is open in the browser.
        case pending
        case connected(account: String)
        /// Google refused the grant (removed or expired): connect again.
        case needsReauth(account: String?)
    }

    public typealias Scope = GitHubConnections.Scope
    @ObservationIgnored private let scope: @MainActor () -> Scope?
    @ObservationIgnored private let call: GitHubConnections.Call
    @ObservationIgnored private let open: (URL) -> Void
    private var loadedScope: Scope?
    private var rows: [JSONValue] = []
    private var configured: Set<Provider> = []
    private var working: Set<Provider> = []
    private var failedScope: Scope?
    private var generation = 0
    @ObservationIgnored private var connectKeys: [ConnectKey: String] = [:]
    private struct ConnectKey: Hashable { var scope: Scope; var provider: Provider }

    public init(scope: @escaping @MainActor () -> Scope?, call: @escaping GitHubConnections.Call, open: @escaping (URL) -> Void) {
        self.scope = scope
        self.call = call
        self.open = open
    }

    /// The last list, a gesture or the list failed for the current scope.
    public var failed: Bool { scope() != nil && failedScope == scope() }
    public func isWorking(_ provider: Provider) -> Bool { working.contains(provider) }

    public func state(_ provider: Provider) -> State {
        guard let current = scope() else { return .signedOut }
        guard loadedScope == current, configured.contains(provider) else { return .unavailable }
        guard let row = shownRow(provider) else { return .notConnected }
        let account = row["account"]?["name"]?.stringValue
        switch row["status"]?.stringValue {
        case "active": return .connected(account: account ?? "")
        case "pending": return .pending
        default: return .needsReauth(account: account)
        }
    }

    /// The row the provider's state shows: an active one first (the person's own before a
    /// teammate's), then a broken one, then a pending one, the person's own first in each.
    private func shownRow(_ provider: Provider) -> JSONValue? {
        let user = scope()?.user
        let mine = rows.filter { $0["provider"]?.stringValue == provider.rawValue }
        for statuses in [["active"], ["needs_reauth", "error"], ["pending"]] {
            let matching = mine.filter { statuses.contains($0["status"]?.stringValue ?? "") }
            if let row = matching.first(where: { $0["created_by"]?.stringValue == user }) ?? matching.first { return row }
        }
        return nil
    }

    /// The shown connection of `provider` when the person made it, which Disconnect revokes; nil for
    /// a team connection someone else made (only its maker may revoke it), so Disconnect never
    /// revokes a row other than the one the card shows.
    func ownConnection(_ provider: Provider) -> String? {
        guard let current = scope(), loadedScope == current, let row = shownRow(provider),
              row["created_by"]?.stringValue == current.user else { return nil }
        return row["id"]?.stringValue
    }

    public func canDisconnect(_ provider: Provider) -> Bool { ownConnection(provider) != nil }

    /// Reads the team's connections again.
    public func refresh() async {
        guard let bound = scope() else { return }
        generation += 1
        let ticket = generation
        do {
            try await load(bound, ticket: ticket)
            if scope() == bound, generation == ticket { failedScope = nil }
        } catch {
            if scope() == bound, generation == ticket { failedScope = bound }
        }
    }

    /// Starts connecting `provider` (a private connection) and opens Google's approval page.
    public func connect(_ provider: Provider) async {
        await gesture(provider) { bound in
            // One key per account and provider: a second click while Google's page is still open
            // replays the same pending connection instead of making another.
            let key = self.connectKeys[ConnectKey(scope: bound, provider: provider), default: UUID().uuidString]
            self.connectKeys[ConnectKey(scope: bound, provider: provider)] = key
            let value = try await self.call(bound, "integration.connect", ["provider": .string(provider.rawValue), "sharing": "private"], key)
            guard let raw = value["authorize_url"]?.stringValue, let url = Self.authorizeURL(raw) else { throw Failure.invalidReply }
            guard self.scope() == bound else { throw Failure.changedAccount }
            self.open(url)
        }
    }

    /// Revokes the person's own connection of `provider`; the gateway deletes its token at once.
    public func disconnect(_ provider: Provider) async {
        guard let connection = ownConnection(provider) else { return }
        await gesture(provider) { bound in
            _ = try await self.call(bound, "integration.revoke", ["connection": .string(connection)], UUID().uuidString)
        }
    }

    private func gesture(_ provider: Provider, _ work: @escaping @MainActor (Scope) async throws -> Void) async {
        guard let bound = scope(), !working.contains(provider) else { return }
        working.insert(provider)
        defer { working.remove(provider) }
        failedScope = nil
        do {
            try await work(bound)
            // The list read after the gesture wins over a refresh that started before it landed.
            generation += 1
            try await load(bound, ticket: generation)
        } catch {
            if scope() == bound { failedScope = bound }
            // The gesture may have taken even when its answer was lost: show what the list says now.
            generation += 1
            try? await load(bound, ticket: generation)
        }
    }

    private func load(_ bound: Scope, ticket: Int) async throws {
        let value = try await call(bound, "integration.list", [:], nil)
        guard scope() == bound, generation == ticket else { return }
        guard let list = value["connections"]?.arrayValue, let providers = value["providers"]?.arrayValue else { throw Failure.invalidReply }
        rows = list.filter { row in
            Provider(rawValue: row["provider"]?.stringValue ?? "") != nil && !["revoked", "expired"].contains(row["status"]?.stringValue ?? "")
        }
        configured = Set(providers.compactMap { item in
            item["configured"]?.boolValue == true ? Provider(rawValue: item["provider"]?.stringValue ?? "") : nil
        })
        loadedScope = bound
        for provider in Provider.allCases where !rows.contains(where: {
            $0["provider"]?.stringValue == provider.rawValue && $0["status"]?.stringValue == "pending"
        }) {
            connectKeys[ConnectKey(scope: bound, provider: provider)] = nil
        }
    }

    /// Only Google's OAuth consent page may open: https, accounts.google.com, the v2 auth path, no
    /// user, password or port. Anything else the server answers is refused.
    public nonisolated static func authorizeURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "https", url.host == "accounts.google.com",
              url.user == nil, url.password == nil, url.port == nil, url.path == "/o/oauth2/v2/auth" else { return nil }
        return url
    }

    enum Failure: Error { case invalidReply, changedAccount }
}

extension ChiefConnections {
    /// The connections of the Cloud sign-in `auth`, through the owner API at `ownerAPI`, with the
    /// same signed-in scope and op call as ``GitHubConnections/live(auth:ownerAPI:preview:)``;
    /// `preview` (showcase or fixture launches) is always signed out. Google's page opens through LinkRouter.
    public static func live(auth: CloudAuth, ownerAPI: URL, preview: Bool) -> ChiefConnections {
        let (scope, call) = GitHubConnections.liveCall(auth: auth, ownerAPI: ownerAPI, preview: preview)
        return ChiefConnections(scope: scope, call: call, open: { url in LinkRouter.shared.open(url) })
    }
}
