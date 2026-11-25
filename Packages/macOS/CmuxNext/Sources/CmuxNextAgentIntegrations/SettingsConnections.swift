public import CmuxNextPages
public import CmuxNextSettings
public import Foundation
public import Observation
import CmuxNextCompat

/// Settings > Integrations > Connections: the remote MCP servers a person connects once in cmux (cmux platform
/// `/v1/mcp-servers`), whose tools every agent chat then gets through cmux's hosted MCP server.
/// The state is the bundled `cmux mcp-servers catalog --json`; Connect, Reconnect, Disconnect and
/// Enable run `cmux mcp-servers ...`, only on the person's click. The CLI owns every request, error
/// and label (cmux-tui `cli/mcp_servers.rs`): this type only relays, and opens a provider's sign-in
/// page in a cmux browser tab (as Settings > MCP Servers does; the system browser when no window can take it)
/// with a `return_to` link back to this page (`<scheme>://settings/integrations`), which the tab hands to the
/// app with no prompt before it closes (`BrowserExternalApps.isFlowReturn`).
///
/// A key-auth server's key goes to the CLI's stdin and nowhere else: never an argument, the
/// environment, the state or a log.
///
/// Leo, 2026-11-24: "i think we might as well just go ahead and add a bunch of integrations into
/// our app that people would want... we can just set up allllll the backend shit and whatever may
/// be useful.... just code up and merge the ones we care about if they dont already exist"
@MainActor
@Observable
public final class SettingsConnections: PageProvider {
    public static let stateOp = "cmux.settings.connections.state"
    public static let runOp = "cmux.settings.connections.run"
    /// The settings link path a sign-in returns to (DeepLink.settingsRoute).
    public static let returnPath = "settings/integrations"

    /// The CLI's catalog answer, as it printed it (webviews/src/pages/settings/ops.ts `ConnectionsCatalog`).
    private(set) var catalog: JSONValue = .null
    private(set) var loading = false
    /// `unavailable` (no bundled cmux CLI) or `failed` (the catalog did not answer).
    private(set) var problem: String?
    /// The last action's refusal, in the CLI's words.
    private(set) var lastError: (action: String, code: String, message: String)?
    /// The server whose sign-in page the last Connect or Reconnect opened, until a refresh shows it connected.
    private(set) var pending: String?

    @ObservationIgnored private let cli: @MainActor () async -> URL?
    @ObservationIgnored private let linkScheme: @MainActor () -> String
    @ObservationIgnored private let openInBrowser: @MainActor (URL) -> Void
    @ObservationIgnored private let runCLI: @Sendable (URL, [String], Data?) async throws -> (Int32, Data, Data)
    @ObservationIgnored private var generation = 0

    public init(cli: @escaping @MainActor () async -> URL?,
                linkScheme: @escaping @MainActor () -> String,
                openInBrowser: @escaping @MainActor (URL) -> Void,
                runCLI: @escaping @Sendable (URL, [String], Data?) async throws -> (Int32, Data, Data) = SettingsIntegrationsHub.run) {
        self.cli = cli
        self.linkScheme = linkScheme
        self.openInBrowser = openInBrowser
        self.runCLI = runCLI
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case Self.stateOp: return state
        case Self.runOp: return try await run(params, context: context)
        default: throw PageError.unknownOp(op)
        }
    }

    /// The page's `cmux.settings.connections.state`.
    var state: JSONValue {
        [
            "loading": .bool(loading),
            "problem": problem.map(JSONValue.string) ?? .null,
            "catalog": catalog,
            "error": lastError.map { ["action": .string($0.action), "code": .string($0.code), "message": .string($0.message)] } ?? .null,
            "pending": pending.map(JSONValue.string) ?? .null,
        ]
    }

    /// One gesture: `refresh`; `connect` with a catalog `name`, `owner` (`me`, `team`), an
    /// optional `team` id and, for a key-auth server, `key`; `reconnect`, `remove` or `enable`
    /// with a listed connection `id`. Only refresh runs without the person's click.
    func run(_ params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let action = params["action"]?.stringValue ?? ""
        if action == "refresh" {
            await refresh()
            return .object([:])
        }
        guard context.userGesture || context.isConfirmedUser else {
            throw PageError(code: PageNativeOp.userOnlyCode, message: "\(action) needs a click in the page")
        }
        let returnTo = "\(linkScheme())://\(Self.returnPath)"
        let words = try Self.arguments(action: action, params: params, catalog: catalog, returnTo: returnTo)
        let stdin: Data? = words.contains("--key-stdin") ? SettingsIntegrationsHub.keyData(params) : nil
        if words.contains("--key-stdin"), stdin == nil { throw PageError.invalidParams("paste the server's key") }
        guard let cli = await cli() else { throw PageError(code: "cmux.page.unavailable", message: "no bundled cmux CLI") }
        let reply = try? await awaitConcurrently({ try await runCLI(cli, ["mcp-servers"] + words + ["--json"], stdin) })
        let answer = reply.flatMap { SettingsIntegrationsHub.lastLine($0.1) }
        if let answer, answer["ok"]?.boolValue == true {
            lastError = nil
            if let page = answer["authorizeUrl"]?.stringValue, let url = Self.signInPage(page) {
                pending = params["name"]?.stringValue ?? Self.name(catalog, connection: params["id"]?.stringValue)
                openInBrowser(url)
            }
        } else {
            lastError = (action,
                         answer?["error"]?["code"]?.stringValue ?? "cli.failed",
                         answer?["error"]?["message"]?.stringValue ?? "")
        }
        await refresh()
        return answer ?? .object([:])
    }

    /// Whether `url` is this page's settings link, the one a provider's sign-in returns to
    /// (`<scheme>://settings/integrations` or `/connections`, any of this build's schemes).
    public nonisolated static func isReturn(_ url: URL) -> Bool {
        guard url.host?.lowercased() == "settings" else { return false }
        return ["/integrations", "/integrations/", "/connections", "/connections/"].contains(url.path.lowercased())
    }

    /// The sign-in page to open: https only.
    nonisolated static func signInPage(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// The catalog entries the CLI listed.
    nonisolated static func entries(_ catalog: JSONValue) -> [JSONValue] {
        catalog["entries"]?.arrayValue ?? []
    }

    /// The catalog name of a listed connection.
    nonisolated static func name(_ catalog: JSONValue, connection: String?) -> String? {
        guard let connection else { return nil }
        return entries(catalog).first { $0["connectionId"]?.stringValue == connection }?["name"]?.stringValue
    }

    /// The CLI words (after `mcp-servers`) for one action. Every name and id is one the card was
    /// shown, so a page script cannot pass flags of its own.
    nonisolated static func arguments(action: String, params: JSONValue, catalog: JSONValue, returnTo: String) throws -> [String] {
        let id = params["id"]?.stringValue ?? ""
        let connections = Set(entries(catalog).compactMap { $0["connectionId"]?.stringValue })
        switch action {
        case "connect":
            let name = params["name"]?.stringValue ?? ""
            guard let entry = entries(catalog).first(where: { $0["name"]?.stringValue == name }),
                  entry["state"]?.stringValue == "connect" else {
                throw PageError.invalidParams("name must be a listed server that is not connected")
            }
            let owner = params["owner"]?.stringValue ?? "me"
            guard owner == "me" || owner == "team" else { throw PageError.invalidParams("owner is me or team") }
            var words = ["connect", name, "--owner", owner, "--return-to", returnTo]
            if let team = params["team"]?.stringValue {
                guard !team.isEmpty, !team.hasPrefix("-"), team.count <= 128,
                      team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
                    throw PageError.invalidParams("team must be a team id")
                }
                words += ["--team", team]
            }
            if entry["keyField"]?.boolValue == true { words.append("--key-stdin") }
            return words
        case "reconnect":
            guard connections.contains(id) else { throw PageError.invalidParams("id must be a listed connection") }
            return ["reconnect", id, "--return-to", returnTo]
        case "remove", "enable":
            guard connections.contains(id) else { throw PageError.invalidParams("id must be a listed connection") }
            return [action, id]
        default:
            throw PageError.invalidParams("unknown action \(action)")
        }
    }

    /// Reads the catalog again; only the newest read writes it. A pending sign-in clears once its
    /// server shows connected.
    public func refresh() async {
        guard let cli = await cli() else {
            catalog = .null
            problem = "unavailable"
            return
        }
        generation += 1
        let mine = generation
        loading = true
        let reply = try? await awaitConcurrently({ try await runCLI(cli, ["mcp-servers", "catalog", "--json"], nil) })
        guard mine == generation else { return }
        loading = false
        guard let reply, let value = SettingsIntegrationsHub.lastLine(reply.1) else {
            problem = "failed"
            return
        }
        catalog = value
        problem = value["ok"]?.boolValue == true ? nil : "failed"
        if let pending, Self.entries(value).contains(where: { $0["name"]?.stringValue == pending && $0["state"]?.stringValue == "connected" }) {
            self.pending = nil
        }
    }
}
