public import CmuxNextAgentPane
public import CmuxNextCloud
import CmuxNextDaemonService
public import CmuxNextPages
public import CmuxNextSettings
public import Foundation

/// Settings > Accounts and Devices > Connectors: relays the page's `cmux.settings.connectors.list`,
/// `.connect` and `.disconnect` to cmux-platform's connectors API (`/v1/connectors`, cmux-platform
/// docs/connectors.md) as the signed-in person, for the team selected in Settings > Accounts (none: the
/// person's own). The platform owns the catalog, each connection's state and sharing; the page
/// (webviews/src/pages/settings/connectors.ts) shapes the rows. This type only picks the path, adds the
/// person's token and opens the provider's approval page, so no connector rule lives here. Connect and
/// Disconnect run only on the person's click in Settings; reading the list does not.
@MainActor
public final class SettingsConnectors: PageProvider {
    public nonisolated static let prefix = "cmux.settings.connectors."

    /// The account and team a request acts for (``GitHubConnections/Scope``), bound once per call.
    public typealias Scope = GitHubConnections.Scope
    /// The platform's answer to METHOD at PATH with QUERY (GET only) for SCOPE (team in the `x-cmux-team` header).
    public typealias Send = @MainActor (_ method: String, _ path: String, _ query: [String: String], _ scope: Scope) async throws
        -> (status: Int, body: Data)

    private let scope: @MainActor () -> Scope?
    private let send: Send
    private let open: @MainActor (URL) -> Void
    private let preview: Bool

    /// SCOPE answers the signed-in person and selected team now, or nil (signed out, or a managed team other
    /// than the selected one is enforced); SEND reaches the platform; OPEN shows the provider's approval page.
    public init(scope: @escaping @MainActor () -> Scope?, send: @escaping Send,
                open: @escaping @MainActor (URL) -> Void, preview: Bool) {
        self.scope = scope
        self.send = send
        self.open = open
        self.preview = preview
    }

    /// AUTH's sign-in at PLATFORM (the selected backend's cmux-platform origin); PREVIEW (showcase or
    /// fixture launches) lists nothing. The scope is ``GitHubConnections/signedInScope``'s, so a device
    /// restricted to a managed team never falls back to the person's own connectors.
    public convenience init(auth: CloudAuth, platform: URL, preview: Bool) {
        let project = auth.configuration.stackProjectID
        let scope: @MainActor () -> Scope? = {
            guard auth.isSignedIn, let user = auth.user?.id else { return nil }
            return GitHubConnections.signedInScope(project: project, user: user, team: auth.teamID, managedTeam: auth.managedTeamID)
        }
        self.init(scope: scope, send: { method, path, query, bound in
            let access = try await auth.tokens().access
            // The token resolved after a switch: refuse rather than act for the new account or team.
            guard scope() == bound else { throw Self.changed }
            let team = GitHubConnections.backendTeam(project: project, stackTeam: bound.team)
            let headers = team.map { ["x-cmux-team": $0] } ?? [:]
            let transport = InstallHTTPTransport(baseURL: platform)
            guard method == "GET" else { return try await transport.post(path, json: Data("{}".utf8), bearer: access, headers: headers) }
            // A GET also names the team in its query: a platform without connector management (production
            // before it is switched on) reads it only there. A POST's query would be escaped into its path.
            var items = query
            if let team { items["team"] = team }
            var components = URLComponents()
            components.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            let suffix = items.isEmpty ? "" : "?" + (components.percentEncodedQuery ?? "")
            return try await transport.get(path + suffix, bearer: access, headers: headers)
        }, open: { LinkRouter.shared.open($0) }, preview: preview)
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let verb = op.hasPrefix(Self.prefix) ? String(op.dropFirst(Self.prefix.count)) : ""
        switch verb {
        case "list":
            return await list()
        case "connect", "disconnect":
            guard context.page == PageDescriptor.settings.id, context.userGesture || context.isConfirmedUser else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
            }
            let provider = params["provider"]?.stringValue ?? ""
            guard provider.range(of: #"^[a-z][a-z-]{0,31}$"#, options: .regularExpression) != nil else {
                throw PageError.invalidParams("provider")
            }
            // The click acts for the account and team the page showed when it was made (its list's `scope`),
            // never one switched to meanwhile, whether before the click or while its request is out.
            guard let bound = scope() else { throw Self.signedOut }
            guard params["scope"]?.stringValue == Self.key(bound) else { throw Self.changed }
            if verb == "connect" {
                let sharing = params["sharing"]?.stringValue ?? "private"
                guard sharing == "private" || sharing == "team" else { throw PageError.invalidParams("sharing") }
                return try await connect(provider: provider, sharing: sharing, scope: bound)
            }
            let connection = params["connection"]?.stringValue ?? ""
            guard connection.range(of: #"^conn_[a-z0-9]{20}$"#, options: .regularExpression) != nil else {
                throw PageError.invalidParams("connection")
            }
            return try answer(await request("POST", "v1/connectors/\(provider)/connections/\(connection)/revoke", [:], scope: bound))
        default:
            throw PageError.unknownOp(op)
        }
    }

    private static let signedOut = PageError(code: "cmux.settings.connectors.signed_out", message: "not signed in")

    /// `{available, signedIn, team, connectors?, error?, status?}`: `available` false only in a preview;
    /// `status` is the platform's HTTP status when it refused (the page reads 400/404 as "not offered here").
    private func list() async -> JSONValue {
        guard !preview else { return .object(["available": .bool(false)]) }
        // Signed out, or a managed team that is not the selected one: nothing is read for anyone.
        guard let bound = scope() else { return .object(["available": .bool(true), "signedIn": .bool(false)]) }
        var status: Int?
        do {
            let response = try await request("GET", "v1/connectors/", [:], scope: bound)
            status = response.status
            let reply = try answer(response)
            guard case .object(var fields) = reply else { throw PageError.invalidParams("connectors reply") }
            fields["available"] = .bool(true)
            fields["signedIn"] = .bool(true)
            fields["team"] = bound.team.map(JSONValue.string) ?? .null
            fields["scope"] = .string(Self.key(bound))
            return .object(fields)
        } catch {
            let message = (error as? PageError)?.message ?? error.localizedDescription
            var fields: [String: JSONValue] = ["available": .bool(true), "signedIn": .bool(true), "error": .string(message)]
            if let status, !(200..<300).contains(status) { fields["status"] = .number(Double(status)) }
            return .object(fields)
        }
    }

    /// Asks for the provider's approval URL and opens it in the browser; the connection becomes active
    /// when the person approves there, and the page reads the list again when it comes back to the front.
    private func connect(provider: String, sharing: String, scope bound: Scope) async throws -> JSONValue {
        let reply = try answer(await request("GET", "v1/connectors/\(provider)/install", ["sharing": sharing], scope: bound))
        guard let raw = reply["url"]?.stringValue, let url = URL(string: raw), url.scheme == "https", url.host != nil else {
            throw PageError(code: "cmux.settings.connectors.invalid_reply", message: "no approval page")
        }
        open(url)
        return .object(["opened": .bool(true)])
    }

    /// SEND for BOUND, refused when the account or team changed before it went out or before its answer is
    /// used: an approval page or a revoke never acts for a team other than the one the person clicked in.
    private func request(_ method: String, _ path: String, _ query: [String: String], scope bound: Scope) async throws
        -> (status: Int, body: Data) {
        guard !preview else { throw Self.signedOut }
        guard scope() == bound else { throw Self.changed }
        let response = try await send(method, path, query, bound)
        guard scope() == bound else { throw Self.changed }
        return response
    }

    private static let changed = PageError(code: "cmux.settings.connectors.changed", message: "account or team changed")

    /// SCOPE as the page holds it: opaque to the page, compared whole here.
    nonisolated static func key(_ scope: Scope) -> String { scope.user + "\u{1F}" + (scope.team ?? "") }

    /// The platform's JSON on 2xx; its own `message` (fixed text, never a provider body) otherwise.
    private func answer(_ response: (status: Int, body: Data)) throws -> JSONValue {
        let reply = try? JSONValue.parse(response.body)
        guard (200..<300).contains(response.status), let reply else {
            throw PageError(code: "cmux.settings.connectors.refused", message: reply?["message"]?.stringValue ?? "HTTP \(response.status)")
        }
        return reply
    }
}

extension SettingsConnectors {
    /// The Accounts domain's Settings routes: Connectors (AUTH at PLATFORM) and This Mac on Your Tailnet (sign in
    /// and out on the app's person connection to the acpmux ENVIRONMENT names).
    public static func routes(auth: CloudAuth, platform: URL, preview: Bool,
                              environment: @escaping @MainActor () -> AcpmuxEnvironment?) -> [PageRoute] {
        [PageRoute(prefix: prefix, provider: SettingsConnectors(auth: auth, platform: platform, preview: preview)),
         PageRoute(prefix: SettingsTailnet.prefix, provider: SettingsTailnet(environment: environment))]
    }
}
