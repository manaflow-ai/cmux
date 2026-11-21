public import CmuxNextPages
public import CmuxNextSettings
public import Foundation

/// Settings > Agents > Claude Code & Codex > Hooks (Labs `labs.agentCustomization`): every Claude Code
/// and Codex hook on this Mac, by agent, event and matcher, with its command, scope and whether it
/// runs. The rows are the bundled `cmux --json agent-config hooks list` (cmux-agent-customize
/// hooks.rs, which reads and writes the agents' own files); Turn Off / Turn On run `hooks disable|enable
/// ID`, Remove runs `hooks remove ID` and Add runs `hooks add`. The CLI owns every read and write, so
/// this type only relays; with the Labs switch off it answers `available: false` and runs nothing.
///
/// Leo, 2026-11-19: "Claude Code, Codex and Rex customization visible in cmux"; "actually looking at
/// the functionality, testing it out".
@MainActor
public final class SettingsAgentHooks: PageProvider {
    public static let stateOp = "cmux.settings.agentHooks.state"
    public static let runOp = "cmux.settings.agentHooks.run"

    private let cli: @MainActor () async -> URL?
    private let enabled: @MainActor () -> Bool
    private let runCLI: @Sendable (URL, [String]) async throws -> (Int32, Data, Data)
    /// The last list answer, kept so a page reload shows it at once while it is read again.
    private var listing: JSONValue?
    private var error: String?

    public init(cli: @escaping @MainActor () async -> URL?, enabled: @escaping @MainActor () -> Bool,
                runCLI: @escaping @Sendable (URL, [String]) async throws -> (Int32, Data, Data) = SettingsAgentIntegrations.run) {
        self.cli = cli
        self.enabled = enabled
        self.runCLI = runCLI
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case Self.stateOp: return state
        case Self.runOp: return try await run(params, context: context)
        default: throw PageError.unknownOp(op)
        }
    }

    /// The page's `cmux.settings.agentHooks.state` (webviews/src/pages/settings/ops.ts `AgentHooksState`).
    var state: JSONValue {
        guard enabled() else { return ["available": .bool(false)] }
        return [
            "available": .bool(true),
            "listing": listing ?? .null,
            "error": error.map(JSONValue.string) ?? .null,
        ]
    }

    /// One gesture: `refresh` reads; `enable`, `disable` and `remove` take a listed `id`; `add` takes
    /// `agent`, `event`, `command` and optional `matcher`, `timeout`, `scope`. Edits run only on the
    /// person's click in the page (`context.userGesture`) or a call they approved.
    func run(_ params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard enabled() else { return state }
        let action = params["action"]?.stringValue ?? ""
        var arguments: [String]
        switch action {
        case "refresh":
            await refresh()
            return state
        case "enable", "disable", "remove":
            guard let id = params["id"]?.stringValue, Self.ids(listing).contains(id) else {
                throw PageError.invalidParams("id must be a listed hook")
            }
            arguments = [action, id]
        case "add":
            guard let agent = params["agent"]?.stringValue, ["claude", "codex"].contains(agent),
                  let event = params["event"]?.stringValue, !event.isEmpty,
                  let command = params["command"]?.stringValue, !command.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw PageError.invalidParams("add needs agent, event and command")
            }
            arguments = ["add", "--agent", agent, "--event", event, "--command", command]
            if let matcher = params["matcher"]?.stringValue, !matcher.isEmpty { arguments += ["--matcher", matcher] }
            if let timeout = params["timeout"]?.intValue, timeout > 0 { arguments += ["--timeout", String(timeout)] }
            if let scope = params["scope"]?.stringValue, ["user", "user-local"].contains(scope) { arguments += ["--scope", scope] }
        default:
            throw PageError.invalidParams("unknown hooks action \(action)")
        }
        guard context.userGesture || context.isConfirmedUser else {
            throw PageError(code: PageNativeOp.userOnlyCode, message: "\(action) needs a click in the page")
        }
        guard let cli = await cli() else { throw PageError(code: "cmux.page.unavailable", message: "no bundled cmux") }
        let reply = try? await runCLI(cli, ["--json", "agent-config", "hooks"] + arguments)
        await refresh()
        if let reply, reply.0 != 0 {
            error = Self.refusal(stdout: reply.1, stderr: reply.2) ?? "the change did not finish"
        } else if reply == nil {
            error = "the change did not finish"
        }
        return state
    }

    /// Reads the list again (`hooks list`); a failed read keeps the last list and says why.
    func refresh() async {
        error = nil
        guard let cli = await cli() else {
            error = "no bundled cmux"
            return
        }
        guard let reply = try? await runCLI(cli, ["--json", "agent-config", "hooks", "list"]), reply.0 == 0,
              let value = SettingsAgentMcpServers.lastLine(reply.1), value["hooks"]?.arrayValue != nil else {
            error = "the hooks list did not answer"
            return
        }
        listing = value
    }

    static func ids(_ listing: JSONValue?) -> Set<String> {
        Set((listing?["hooks"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue })
    }

    /// The CLI's refusal: with `--json` it prints `{"ok":false,"why":...}` on stdout's last line
    /// (cmux-tui cli/agent_config.rs `run_hooks`); else its stderr text.
    nonisolated static func refusal(stdout: Data, stderr: Data) -> String? {
        if let why = SettingsAgentMcpServers.why(stdout), !why.isEmpty { return why }
        let text = String(data: stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
}
