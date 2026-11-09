public import CmuxNextAgentPane
public import CmuxNextCloud
import CmuxNextDaemonService
public import CmuxNextPages
public import CmuxNextSettings
import Foundation

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

    private let auth: CloudAuth
    private let platform: URL
    private let preview: Bool

    /// AUTH's sign-in at PLATFORM (the selected backend's cmux-platform origin); PREVIEW (showcase or
    /// fixture launches) lists nothing.
    public init(auth: CloudAuth, platform: URL, preview: Bool) {
        self.auth = auth
        self.platform = platform
        self.preview = preview
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
            if verb == "connect" {
                let sharing = params["sharing"]?.stringValue ?? "private"
                guard sharing == "private" || sharing == "team" else { throw PageError.invalidParams("sharing") }
                return try await connect(provider: provider, sharing: sharing)
            }
            let connection = params["connection"]?.stringValue ?? ""
            guard connection.range(of: #"^conn_[a-z0-9]{20}$"#, options: .regularExpression) != nil else {
                throw PageError.invalidParams("connection")
            }
            return try await answer(post(path: "v1/connectors/\(provider)/connections/\(connection)/revoke" + query([:])))
        default:
            throw PageError.unknownOp(op)
        }
    }

    /// `{available, signedIn, team, connectors?, error?}`: `available` false only in a preview.
    private func list() async -> JSONValue {
        guard !preview else { return .object(["available": .bool(false)]) }
        guard auth.isSignedIn else { return .object(["available": .bool(true), "signedIn": .bool(false)]) }
        do {
            let reply = try answer(await get(path: "v1/connectors/" + query([:])))
            guard case .object(var fields) = reply else { throw PageError.invalidParams("connectors reply") }
            fields["available"] = .bool(true)
            fields["signedIn"] = .bool(true)
            fields["team"] = team.map(JSONValue.string) ?? .null
            return .object(fields)
        } catch {
            let message = (error as? PageError)?.message ?? error.localizedDescription
            return .object(["available": .bool(true), "signedIn": .bool(true), "error": .string(message)])
        }
    }

    /// Asks for the provider's approval URL and opens it in the browser; the connection becomes active
    /// when the person approves there, and the page reads the list again when it comes back to the front.
    private func connect(provider: String, sharing: String) async throws -> JSONValue {
        let reply = try answer(await get(path: "v1/connectors/\(provider)/install" + query(["sharing": sharing])))
        guard let raw = reply["url"]?.stringValue, let url = URL(string: raw), url.scheme == "https", url.host != nil else {
            throw PageError(code: "cmux.settings.connectors.invalid_reply", message: "no approval page")
        }
        LinkRouter.shared.open(url)
        return .object(["opened": .bool(true)])
    }

    /// The selected team as the backend names it (``GitHubConnections/backendTeam``); nil: the person's own.
    private var team: String? {
        GitHubConnections.backendTeam(project: auth.configuration.stackProjectID, stackTeam: auth.teamID)
    }

    private func query(_ extra: [String: String]) -> String {
        var items = extra.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        if let team { items.insert(URLQueryItem(name: "team", value: team), at: 0) }
        guard !items.isEmpty else { return "" }
        var components = URLComponents()
        components.queryItems = items
        return "?" + (components.percentEncodedQuery ?? "")
    }

    private func get(path: String) async throws -> (status: Int, body: Data) {
        try await InstallHTTPTransport(baseURL: platform).get(path, bearer: auth.tokens().access, headers: [:])
    }

    private func post(path: String) async throws -> (status: Int, body: Data) {
        try await InstallHTTPTransport(baseURL: platform).post(path, json: Data("{}".utf8), bearer: auth.tokens().access, headers: [:])
    }

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
