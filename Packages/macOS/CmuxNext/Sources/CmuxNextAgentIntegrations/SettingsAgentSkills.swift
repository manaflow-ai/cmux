import AppKit
import CmuxNextCompat
public import CmuxNextPages
public import CmuxNextSettings
public import Foundation

/// Settings > Agents > Claude Code & Codex > Skills (Labs `labs.agentCustomization`): every skill
/// and slash command Claude Code and Codex load, from the bundled `cmux agent-config skills list
/// --json`, which reads the agents' own folders (and Codex's own app-server). Edit opens the file
/// in cmux's editor, Reveal shows it in Finder, and the switch runs `cmux agent-config skills
/// on|off FILE`, which writes the agent's own setting. The CLI owns every read and write; this type
/// relays. Nothing runs until the page asks, and a write runs only on the person's click. With the
/// Labs switch off the card has nothing (`enabled: false`) and no CLI runs.
@MainActor
public final class SettingsAgentSkills: PageProvider {
    public static let stateOp = "cmux.settings.agentSkills.state"
    public static let runOp = "cmux.settings.agentSkills.run"

    private let cli: @MainActor () async -> URL?
    private let enabled: @MainActor () -> Bool
    private let workingFolder: @MainActor () -> URL?
    private let openFile: @MainActor (URL) -> Void
    private let reveal: @MainActor (URL) -> Void
    private let runCLI: @Sendable (URL, [String], [String: String]) async throws -> (Int32, Data, Data)
    /// The CLI's last listing (`skills`, `problems`, `sources`, `counts`, `elapsedMs`), as it printed it.
    private var listing: JSONValue = .null
    private var loading = false
    /// `unavailable` (no bundled CLI) or `failed` (the list did not answer).
    private var problem: String?
    /// The CLI's refusal of the last switch, in its own words, with the file it was for.
    private var refusal: (path: String, message: String)?
    private var generation = 0

    /// `workingFolder`: the folder whose project skills count (the focused terminal's), nil for the
    /// person's own only.
    public init(cli: @escaping @MainActor () async -> URL?,
                enabled: @escaping @MainActor () -> Bool,
                workingFolder: @escaping @MainActor () -> URL? = { nil },
                openFile: @escaping @MainActor (URL) -> Void,
                reveal: (@MainActor (URL) -> Void)? = nil,
                runCLI: @escaping @Sendable (URL, [String], [String: String]) async throws -> (Int32, Data, Data) = SettingsMcpServers.run) {
        self.cli = cli
        self.enabled = enabled
        self.workingFolder = workingFolder
        self.openFile = openFile
        self.reveal = reveal ?? { NSWorkspace.shared.revealInBackground([$0]) }
        self.runCLI = runCLI
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case Self.stateOp: return state
        case Self.runOp: return try await run(params, context: context)
        default: throw PageError.unknownOp(op)
        }
    }

    /// The page's `AgentSkillsState` (webviews/src/pages/settings/ops.ts).
    var state: JSONValue {
        guard enabled() else { return ["enabled": .bool(false)] }
        return [
            "enabled": .bool(true),
            "loading": .bool(loading),
            "problem": problem.map(JSONValue.string) ?? .null,
            "skills": listing["skills"] ?? .array([]),
            "problems": listing["problems"] ?? .array([]),
            "sources": listing["sources"] ?? .null,
            "counts": listing["counts"] ?? .null,
            "elapsedMs": listing["elapsedMs"] ?? .null,
            "refusal": refusal.map { ["path": .string($0.path), "message": .string($0.message)] } ?? .null,
        ]
    }

    /// `refresh` reads; `open` and `reveal` show a listed file; `on` / `off` (`path`) write the
    /// agent's own setting, only on the person's click (`context.userGesture`) or a call they approved.
    func run(_ params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard enabled() else { return state }
        let action = params["action"]?.stringValue ?? ""
        switch action {
        case "refresh":
            await refresh()
        case "open", "reveal":
            let file = try listed(params)
            action == "open" ? openFile(file) : reveal(file)
        case "on", "off":
            guard context.userGesture || context.isConfirmedUser else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: "\(action) needs a click in the page")
            }
            let file = try listed(params)
            guard let cli = await cli() else { throw PageError(code: "cmux.page.unavailable", message: "no bundled cmux CLI") }
            var arguments = ["agent-config", "skills", action, file.path(percentEncoded: false), "--json"]
            if let agent = params["agent"]?.stringValue, agent == "claude" || agent == "codex" {
                arguments += ["--agent", agent]
            }
            if let folder = workingFolder() { arguments += ["--cwd", folder.path(percentEncoded: false)] }
            let path = file.path(percentEncoded: false)
            if let reply = try? await runCLI(cli, arguments, [:]) {
                refusal = await Self.refusal(reply).map { (path: path, message: $0) }
            } else {
                // No answer at all is a refusal with no words of its own.
                refusal = (path: path, message: "")
            }
            await refresh()
        default:
            throw PageError.invalidParams("unknown skills action \(action)")
        }
        return state
    }

    /// The file a gesture names, only when the last listing has it: the page names a row, never an
    /// arbitrary path.
    private func listed(_ params: JSONValue) throws -> URL {
        guard let path = params["path"]?.stringValue,
              listing["skills"]?.arrayValue?.contains(where: { $0["path"]?.stringValue == path }) == true
        else { throw PageError.invalidParams("path must be a listed skill's file") }
        return URL(fileURLWithPath: path)
    }

    /// Reads the list again; only the newest read lands.
    func refresh() async {
        guard let cli = await cli() else {
            problem = "unavailable"
            return
        }
        generation += 1
        let mine = generation
        loading = true
        var arguments = ["agent-config", "skills", "list", "--json"]
        if let folder = workingFolder() { arguments += ["--cwd", folder.path(percentEncoded: false)] }
        let reply = try? await runCLI(cli, arguments, [:])
        guard mine == generation else { return }
        loading = false
        guard let reply, reply.0 == 0, let value = await Self.lastJSON(reply.1), value["skills"]?.arrayValue != nil else {
            problem = "failed"
            return
        }
        listing = value
        problem = nil
    }

    /// The JSON the CLI printed: the whole output, or its last line when something printed before it. Parsed off the
    /// main actor: the skills listing grows with every skill and command the agents load.
    @concurrent nonisolated static func lastJSON(_ data: Data) async -> JSONValue? {
        if let value = try? JSONValue.parse(data) { return value }
        let last = String(data: data, encoding: .utf8)?.split(separator: "\n").last.map { Data($0.utf8) } ?? Data()
        return try? JSONValue.parse(last)
    }

    /// The CLI's refusal (`--json` error envelope on stderr): its message; nil when it succeeded.
    static func refusal(_ reply: (Int32, Data, Data)) async -> String? {
        guard reply.0 != 0 else { return nil }
        let error = await lastJSON(reply.2)
        return error?["error"]?["message"]?.stringValue ?? error?["message"]?.stringValue ?? ""
    }
}
