public import CmuxNextPages
public import CmuxNextSettings
public import Foundation
public import Observation
import CmuxNextCompat

/// Settings > MCP Servers, "Claude Code" and "Codex" (Labs `labs.agentCustomization`): the MCP
/// servers the person gave those agents in their own files, from the bundled
/// `cmux agent-config mcp list --json --project DIR` (cmux-agent-customize `mcp.rs`). Turning one
/// on or off, removing one and adding one run `agent-config mcp enable|disable|remove|add`, only
/// on the person's click. The CLI owns every read and write: this type only relays, and the CLI's
/// rows never hold a secret (env and header values stay in the agents' files).
///
/// Leo, 2026-11-19: "when I say Claude Code, when I say Codex [...] I need you guys to be, like,
/// doing the thing."
@MainActor
@Observable
public final class SettingsAgentMcpServers: PageProvider {
    public static let stateOp = "cmux.settings.agentMcp.state"
    public static let runOp = "cmux.settings.agentMcp.run"

    /// The CLI's `servers`, as it printed them (see webviews/src/pages/settings/ops.ts `AgentMcpServer`).
    private(set) var servers: [JSONValue] = []
    private(set) var problems: [JSONValue] = []
    private(set) var loading = false
    /// `unavailable` (no bundled cmux CLI) or `failed` (the list did not answer).
    private(set) var problem: String?
    /// The last edit's refusal, in the CLI's words, with the row it was for.
    private(set) var lastError: (key: String, why: String)?
    /// How long the last list took, from the click to the rows (ms), and the CLI's own share.
    private(set) var listMs: Double?
    private(set) var cliMs: Double?
    /// The folder Claude Code's per-folder switches and the project files are read for.
    private(set) var project: String

    @ObservationIgnored private let cli: @MainActor () async -> URL?
    @ObservationIgnored private let enabled: @MainActor () -> Bool
    @ObservationIgnored private let pickFolder: @MainActor () async -> URL?
    @ObservationIgnored private let runCLI: @Sendable (URL, [String], [String: String]) async throws -> (Int32, Data, Data)
    @ObservationIgnored private var generation = 0

    public init(cli: @escaping @MainActor () async -> URL?,
                enabled: @escaping @MainActor () -> Bool,
                project: String = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false),
                pickFolder: @escaping @MainActor () async -> URL?,
                runCLI: @escaping @Sendable (URL, [String], [String: String]) async throws -> (Int32, Data, Data) = SettingsMcpServers.run) {
        self.cli = cli
        self.enabled = enabled
        self.pickFolder = pickFolder
        self.runCLI = runCLI
        var folder = project
        while folder.count > 1, folder.hasSuffix("/") { folder.removeLast() }
        self.project = folder
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case Self.stateOp: return state
        case Self.runOp: return try await run(params, context: context)
        default: throw PageError.unknownOp(op)
        }
    }

    /// The page's `cmux.settings.agentMcp.state`. While the Labs switch is off the page gets
    /// `enabled: false` and no rows, and draws nothing.
    var state: JSONValue {
        guard enabled() else { return ["enabled": .bool(false), "servers": .array([])] }
        return [
            "enabled": .bool(true),
            "loading": .bool(loading),
            "problem": problem.map(JSONValue.string) ?? .null,
            "project": .string(project),
            "servers": .array(servers),
            "problems": .array(problems),
            "error": lastError.map { ["key": .string($0.key), "why": .string($0.why)] } ?? .null,
            "listMs": listMs.map(JSONValue.number) ?? .null,
            "cliMs": cliMs.map(JSONValue.number) ?? .null,
        ]
    }

    /// One gesture: `refresh`; `pickFolder`; or `enable` / `disable` / `remove` with `agent`,
    /// `name` and `scope` of a listed row; or `add` with `agent`, `name`, `scope` and `command` +
    /// `args` or `url` (+ `transport`), `env` / `headers` as `KEY=VALUE` lines. Only refresh runs
    /// without the person's click.
    func run(_ params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard enabled() else { throw PageError(code: "cmux.page.unavailable", message: "labs.agentCustomization is off") }
        let action = params["action"]?.stringValue ?? ""
        if action == "refresh" {
            await refresh()
            return .object([:])
        }
        guard context.userGesture || context.isConfirmedUser else {
            throw PageError(code: PageNativeOp.userOnlyCode, message: "\(action) needs a click in the page")
        }
        if action == "pickFolder" {
            if let folder = await pickFolder() {
                var path = folder.path(percentEncoded: false)
                while path.count > 1, path.hasSuffix("/") { path.removeLast() }
                project = path
                await refresh()
            }
            return .object([:])
        }
        let arguments = try Self.arguments(action: action, params: params, listed: servers)
        guard let cli = await cli() else { throw PageError(code: "cmux.page.unavailable", message: "no bundled cmux CLI") }
        let key = Self.key(params)
        let argv = ["agent-config", "mcp"] + Self.withFolder(arguments, project: project)
        let reply = try? await awaitConcurrently({ try await runCLI(cli, argv, [:]) })
        await refresh()
        if let reply, reply.0 == 0 {
            lastError = nil
        } else {
            lastError = (key, reply.flatMap { Self.why($0.1) } ?? "")
        }
        return .object([:])
    }

    /// The row's identity on the page: `agent:scope:name`.
    static func key(_ params: JSONValue) -> String {
        ["agent", "scope", "name"].map { params[$0]?.stringValue ?? "" }.joined(separator: ":")
    }

    /// The CLI words for one edit. A switch or a removal names a row the page was shown; an add
    /// takes only the fields the CLI knows, so a page script cannot pass it flags of its own.
    static func arguments(action: String, params: JSONValue, listed: [JSONValue]) throws -> [String] {
        let agent = params["agent"]?.stringValue ?? ""
        let name = params["name"]?.stringValue ?? ""
        let scope = params["scope"]?.stringValue ?? ""
        guard agent == "claude" || agent == "codex" else { throw PageError.invalidParams("agent must be claude or codex") }
        guard !name.isEmpty, name.count <= 64,
              name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-" })
        else { throw PageError.invalidParams("name: letters, digits, _ and -") }
        guard ["user", "local", "project", "plugin"].contains(scope) else { throw PageError.invalidParams("unknown scope") }
        let head = [name, "--agent", agent, "--scope", scope]
        switch action {
        case "enable", "disable", "remove":
            guard listed.contains(where: {
                $0["agent"]?.stringValue == agent && $0["name"]?.stringValue == name && $0["scope"]?.stringValue == scope
            }) else { throw PageError.invalidParams("name must be a listed server") }
            return [action] + head
        case "add":
            var words = ["add"] + head
            for line in params["env"]?.arrayValue ?? [] {
                guard let text = line.stringValue, text.contains("=") else { continue }
                words += ["--env", text]
            }
            if let url = params["url"]?.stringValue?.trimmingCharacters(in: .whitespaces), !url.isEmpty {
                words += ["--url", url]
                if let transport = params["transport"]?.stringValue, transport == "sse" { words += ["--transport", "sse"] }
                for line in params["headers"]?.arrayValue ?? [] {
                    guard let text = line.stringValue, text.contains("=") else { continue }
                    words += ["--header", text]
                }
                return words
            }
            guard let command = params["command"]?.stringValue?.trimmingCharacters(in: .whitespaces), !command.isEmpty else {
                throw PageError.invalidParams("give a command or a URL")
            }
            let args = (params["args"]?.arrayValue ?? []).compactMap(\.stringValue)
            return words + ["--", command] + args
        default:
            throw PageError.invalidParams("unknown action \(action)")
        }
    }

    /// The folder and --json go before `--`: every word after it is the server's own command.
    nonisolated static func withFolder(_ arguments: [String], project: String) -> [String] {
        var words = arguments
        words.insert(contentsOf: ["--project", project, "--json"], at: words.firstIndex(of: "--") ?? words.endIndex)
        return words
    }

    /// The CLI prints one JSON object, on its last line.
    nonisolated static func lastLine(_ data: Data) -> JSONValue? {
        let last = String(data: data, encoding: .utf8)?.split(separator: "\n").last.map { Data($0.utf8) } ?? Data()
        return try? JSONValue.parse(last)
    }

    /// The CLI's refusal (`{"ok":false,"why":...}`) on its last line.
    nonisolated static func why(_ data: Data) -> String? {
        lastLine(data)?["why"]?.stringValue
    }

    /// Reads the list again; only the newest read writes the rows.
    func refresh() async {
        guard let cli = await cli() else {
            servers = []
            problem = "unavailable"
            return
        }
        generation += 1
        let mine = generation
        loading = true
        let started = ContinuousClock.now
        let argv = ["agent-config", "mcp", "list", "--project", project, "--json"]
        let reply = try? await awaitConcurrently({ try await runCLI(cli, argv, [:]) })
        guard mine == generation else { return }
        loading = false
        guard let reply, reply.0 == 0, let value = Self.lastLine(reply.1), let rows = value["servers"]?.arrayValue else {
            problem = "failed"
            return
        }
        servers = rows
        problems = value["problems"]?.arrayValue ?? []
        cliMs = value["elapsedMs"]?.doubleValue
        let elapsed = ContinuousClock.now - started
        listMs = (Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15).rounded()
        problem = nil
    }
}
