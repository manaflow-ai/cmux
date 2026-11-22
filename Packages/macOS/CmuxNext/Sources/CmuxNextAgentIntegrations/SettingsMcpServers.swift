public import CmuxNextPages
public import CmuxNextSettings
public import Foundation
public import Observation

/// Settings > MCP Servers: the services the person connected for their agents (on a connect card
/// in a chat, or by a Chief), from the machine's one store of connections. The rows are the bundled
/// `optchat-chief integrations --json list`; Sign In runs `integrations --json signin <name>`,
/// which prints the service's sign-in page (opened for the person in their browser) and waits for
/// them; Remove runs `integrations --json remove <name>`, which forgets the server and its sign-in
/// for every agent. The CLI owns every read and write, so this type only relays; nothing runs
/// until the page asks, and the two gestures run only on the person's click.
@MainActor
@Observable
public final class SettingsMcpServers: PageProvider {
    /// One saved server as `integrations --json list` reports it (optchat-chief `settings_row`).
    nonisolated struct Row: Equatable, Sendable {
        var name: String
        /// `remote` (a URL) or `local` (a command on this Mac).
        var kind: String
        var address: String
        var publisher: String
        var verified: Bool
        /// `connected`, `signInNeeded`, `failed` or `unknown`.
        var state: String
        var problem: String?
        /// Who has it: `chat`, `chief`, `allChiefs`, `agents` or `everywhere`.
        var scope: String
        var tools: Int
        /// A sign-in is waiting for the person; `page` is its sign-in page.
        var signingIn = false
        var page: String?
        /// The CLI's refusal of this row's last gesture, in its own words.
        var error: String?
    }

    /// One line of a sign-in: `waiting` with its page, then `connected` or `failed` with why.
    public typealias SignInLine = JSONValue

    private(set) var rows: [Row] = []
    private(set) var loading = false
    /// `unavailable` (no executable optchat-chief beside the CLI) or `failed` (the list did not answer).
    private(set) var problem: String?
    @ObservationIgnored private let chief: @MainActor () async -> URL?
    @ObservationIgnored private let home: @MainActor () async -> URL?
    @ObservationIgnored private let runCLI: @Sendable (URL, [String], [String: String]) async throws -> (Int32, Data, Data)
    @ObservationIgnored private let streamCLI: @Sendable (URL, [String], [String: String], @escaping @Sendable (JSONValue) -> Void) async -> Int32
    @ObservationIgnored private let openPage: @MainActor (URL) -> Void
    @ObservationIgnored private var resolvedHome: URL??
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var signIns: [String: Task<Void, Never>] = [:]

    /// The helper beside the bundled cmux CLI that `cli` finds, run in `home` (the app's own acpmux
    /// home, so the page shows the store this build's agents use); a sign-in page opens through `openPage`.
    public convenience init(cli: @escaping @MainActor () async -> URL?, home: @escaping @MainActor () async -> URL?,
                            openPage: @escaping @MainActor (URL) -> Void) {
        self.init(chief: { await Self.chief(besideCLI: await cli()) }, home: home, openPage: openPage)
    }

    public init(chief: @escaping @MainActor () async -> URL?,
                home: @escaping @MainActor () async -> URL?,
                openPage: @escaping @MainActor (URL) -> Void,
                runCLI: @escaping @Sendable (URL, [String], [String: String]) async throws -> (Int32, Data, Data) = SettingsMcpServers.run,
                streamCLI: @escaping @Sendable (URL, [String], [String: String], @escaping @Sendable (JSONValue) -> Void) async -> Int32 = SettingsMcpServers.stream) {
        self.chief = chief
        self.home = home
        self.openPage = openPage
        self.runCLI = runCLI
        self.streamCLI = streamCLI
    }

    public static let stateOp = "cmux.settings.mcp.state"
    public static let runOp = "cmux.settings.mcp.run"

    /// `cmux.settings.mcp.state` and `.run`; any other op is not this card's.
    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case Self.stateOp: return state
        case Self.runOp: return try await run(params, context: context)
        default: throw PageError.unknownOp(op)
        }
    }

    /// The page's `cmux.settings.mcp.state` (webviews/src/pages/settings/ops.ts `McpServersState`).
    var state: JSONValue {
        [
            "loading": .bool(loading),
            "problem": problem.map(JSONValue.string) ?? .null,
            "servers": .array(rows.map { row in
                [
                    "name": .string(row.name), "kind": .string(row.kind), "address": .string(row.address),
                    "publisher": .string(row.publisher), "verified": .bool(row.verified),
                    "state": .string(row.state), "problem": row.problem.map(JSONValue.string) ?? .null,
                    "scope": .string(row.scope), "tools": .number(Double(row.tools)),
                    "signingIn": .bool(row.signingIn), "page": row.page.map(JSONValue.string) ?? .null,
                    "error": row.error.map(JSONValue.string) ?? .null,
                ]
            }),
        ]
    }

    /// One page gesture (`cmux.settings.mcp.run`): `refresh`, or `signin` / `remove` with a listed
    /// server `name`. Refresh only reads; the others run only on the person's click in the page
    /// (`context.userGesture`) or a call they approved: a page script alone gets `cmux.app.user_only`.
    func run(_ params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let action = params["action"]?.stringValue ?? ""
        switch action {
        case "refresh":
            await refresh()
        case "signin", "remove":
            guard context.userGesture || context.isConfirmedUser else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: "\(action) needs a click in the page")
            }
            guard let name = params["name"]?.stringValue, rows.contains(where: { $0.name == name }) else {
                throw PageError.invalidParams("name must be a listed server")
            }
            guard let chief = await chief() else { throw PageError(code: "cmux.page.unavailable", message: "no optchat-chief") }
            if action == "remove" {
                signIns.removeValue(forKey: name)?.cancel()
                // No answer at all is a refusal with no words of its own.
                let refusal: String?
                if let reply = try? await runCLI(chief, ["integrations", "--json", "remove", name], await environment()) {
                    refusal = await Self.refusal(reply)
                } else {
                    refusal = ""
                }
                await refresh()
                if let refusal, let index = rows.firstIndex(where: { $0.name == name }) {
                    rows[index].error = refusal
                }
            } else {
                startSignIn(name, chief: chief, environment: await environment())
            }
        default:
            throw PageError.invalidParams("unknown MCP servers action \(action)")
        }
        return .object([:])
    }

    /// Runs `signin <name>` until it ends: its sign-in page opens for the person, the row shows it
    /// waiting, and the list is read again at the end. A second click while it waits opens the
    /// page again instead of starting another sign-in.
    private func startSignIn(_ name: String, chief: URL, environment: [String: String]) {
        if signIns[name] != nil, let page = rows.first(where: { $0.name == name })?.page, let url = URL(string: page) {
            openPage(url)
            return
        }
        set(name) { $0.signingIn = true; $0.error = nil }
        let stream = streamCLI
        signIns[name] = Task { [weak self] in
            var failure: String?
            // A sign-in prints two or three lines; the newest few are all that matter.
            let lines = AsyncStream<JSONValue>(bufferingPolicy: .bufferingNewest(16)) { continuation in
                Task {
                    _ = await stream(chief, ["integrations", "--json", "signin", name], environment) { continuation.yield($0) }
                    continuation.finish()
                }
            }
            for await line in lines {
                switch line["status"]?.stringValue {
                case "waiting":
                    if let page = line["page"]?.stringValue, let url = URL(string: page), Self.isWebPage(url) {
                        self?.set(name) { $0.page = page }
                        self?.openPage(url)
                    }
                case "failed": failure = line["why"]?.stringValue ?? ""
                default: break
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.signIns[name] = nil
            await self.refresh()
            if let failure { self.set(name) { $0.error = failure } }
        }
    }

    /// What the helper's environment changes: the app's acpmux home, when it has one. Looked up
    /// once (a path search and a signature check), then kept: the app's home does not move.
    private func environment() async -> [String: String] {
        if resolvedHome == nil { resolvedHome = .some(await home()) }
        guard let home = resolvedHome ?? nil else { return [:] }
        // A folder URL's path ends in `/`; the home is named without it, as acpmux names it.
        var path = home.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return ["ACPMUX_HOME": path]
    }

    private func set(_ name: String, _ change: (inout Row) -> Void) {
        guard let index = rows.firstIndex(where: { $0.name == name }) else { return }
        change(&rows[index])
    }

    /// Only an http(s) page opens: the CLI's line is data, never a command.
    static func isWebPage(_ url: URL) -> Bool {
        url.scheme == "https" || url.scheme == "http"
    }

    /// Reads the list again; only the newest read writes the rows. A sign-in still waiting keeps
    /// its row's wait and page.
    func refresh() async {
        guard let chief = await chief() else {
            rows = []
            problem = "unavailable"
            return
        }
        generation += 1
        let mine = generation
        loading = true
        let reply = try? await runCLI(chief, ["integrations", "--json", "list"], await environment())
        guard mine == generation else { return }
        loading = false
        guard let reply, reply.0 == 0, var read = await Self.rows(reply.1) else {
            problem = "failed"
            return
        }
        for index in read.indices where signIns[read[index].name] != nil {
            read[index].signingIn = true
            read[index].page = rows.first(where: { $0.name == read[index].name })?.page
        }
        rows = read
        problem = nil
    }

    /// The `servers` of a list answer: the whole output, or its last line when something printed before it.
    /// Parsed off the main actor: the output grows with the person's servers.
    @concurrent nonisolated static func rows(_ data: Data) async -> [Row]? {
        let last = String(data: data, encoding: .utf8)?.split(separator: "\n").last.map { Data($0.utf8) } ?? Data()
        guard let value = (try? JSONValue.parse(data)) ?? (try? JSONValue.parse(last)),
              let servers = value["servers"]?.arrayValue else { return nil }
        return servers.compactMap { item in
            guard let name = item["name"]?.stringValue else { return nil }
            return Row(name: name, kind: item["kind"]?.stringValue ?? "remote", address: item["address"]?.stringValue ?? "",
                       publisher: item["publisher"]?.stringValue ?? "", verified: item["verified"]?.boolValue ?? false,
                       state: item["state"]?.stringValue ?? "unknown", problem: item["problem"]?.stringValue,
                       scope: item["scope"]?.stringValue ?? "agents", tools: item["tools"]?.intValue ?? 0)
        }
    }

    /// The CLI's refusal from a failed run's last line; nil when it succeeded.
    @concurrent nonisolated static func refusal(_ reply: (Int32, Data, Data)) async -> String? {
        guard reply.0 != 0 else { return nil }
        let last = String(data: reply.1, encoding: .utf8)?.split(separator: "\n").last.map(String.init) ?? ""
        return (try? JSONValue.parse(Data(last.utf8)))?["why"]?.stringValue ?? ""
    }
}
