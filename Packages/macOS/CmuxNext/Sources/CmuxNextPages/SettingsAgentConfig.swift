import AppKit
public import CmuxNextSettings
public import Foundation
import CmuxNextCompat
import CmuxNextWakeups

/// Settings > Agents > Claude Code & Codex > Settings (webviews `AgentSettingsSection.tsx`, Labs
/// `labs.agentCustomization`): `cmux.settings.agentConfig {verb, agent, key?, value?, scope?, path?}`
/// runs `cmux --json agent-config settings VERB --agent A …` through the bundled CLI and answers its
/// JSON, or its error envelope on a refusal. The reading, the scopes, the masking and every write
/// are the CLI's (cmux-agent-customize `settings.rs`), so the card and the CLI never differ, and
/// this type keeps no state.
///
/// `get` only reads, so the page may ask for it; `set` and `unset` rewrite the agent's own config
/// files and `open` opens one, so they run only on the person's click or key in the page
/// (`context.userGesture`, the host's record) or a call they approved: a page script alone gets
/// `cmux.app.user_only`. `open` opens only a path a fresh `get` lists in `files` and that exists;
/// it creates nothing. While the lab is off every call answers `{"enabled": false}` and runs nothing.
@MainActor
public final class SettingsAgentConfig: PageProvider {
    /// The one op this part serves.
    public static let op = "cmux.settings.agentConfig"
    /// The agents the CLI reads.
    nonisolated static let agents: Set<String> = ["claude", "codex"]
    /// The verbs that need the person's gesture.
    nonisolated static let gestures: Set<String> = ["set", "unset", "open"]
    nonisolated static let timeout: Duration = .seconds(30)

    /// One CLI run: arguments in, exit status, stdout and stderr out.
    public typealias Runner = @Sendable (URL, [String], [String: String]) async throws -> (Int32, Data, Data)
    /// Opens one existing file in the person's default app.
    public typealias Opener = @MainActor (URL) -> Void
    /// Whether a file exists (off the main thread in the app's).
    public typealias Exists = @Sendable (String) async -> Bool

    private let cli: @MainActor () async -> URL?
    private let enabled: @MainActor () -> Bool
    private let runCLI: Runner
    private let openFile: Opener
    private let exists: Exists

    public init(cli: @escaping @MainActor () async -> URL?, enabled: @escaping @MainActor () -> Bool,
                runCLI: @escaping Runner, openFile: @escaping Opener, exists: @escaping Exists) {
        self.cli = cli
        self.enabled = enabled
        self.runCLI = runCLI
        self.openFile = openFile
        self.exists = exists
    }

    /// The app's: the bundled CLI run as a child process; `openFile` is the app's editor in the
    /// current workspace (NSWorkspace when the host gives none).
    public convenience init(cli: @escaping @MainActor () async -> URL?, enabled: @escaping @MainActor () -> Bool,
                            openFile: Opener? = nil) {
        self.init(cli: cli, enabled: enabled,
                  runCLI: { try await SettingsAgentConfig.run($0, $1, $2) },
                  openFile: openFile ?? { url in NSWorkspace.shared.openInBackground(url) },
                  exists: { await SettingsAgentConfig.fileExists($0) })
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == Self.op else { throw PageError.unknownOp(op) }
        guard enabled() else { return .object(["enabled": .bool(false)]) }
        let verb = params["verb"]?.stringValue ?? ""
        guard let agent = params["agent"]?.stringValue, Self.agents.contains(agent) else {
            throw PageError.invalidParams("agent is claude or codex")
        }
        if Self.gestures.contains(verb) {
            guard context.userGesture || context.isConfirmedUser else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: "\(verb) needs a click in the page")
            }
        }
        if verb == "open" { return try await open(agent: agent, params: params) }
        let arguments = try Self.arguments(params)
        return try await runJSON(arguments)
    }

    /// `open`: the path must be one of `files[].path` in a fresh `get` and exist; nothing is created.
    private func open(agent: String, params: JSONValue) async throws -> JSONValue {
        guard let path = params["path"]?.stringValue, !path.isEmpty else { throw PageError.invalidParams("path is a settings file") }
        let state = try await runJSON(Self.getArguments(agent))
        guard Self.listedFiles(state).contains(path) else {
            throw PageError.invalidParams("path is not one of this agent's settings files")
        }
        guard await exists(path) else {
            return .object(["code": .string("agent_config.missing"), "message": .string("the file does not exist yet")])
        }
        openFile(URL(fileURLWithPath: path))
        return .object(["ok": .bool(true)])
    }

    private func runJSON(_ arguments: [String]) async throws -> JSONValue {
        guard let binary = await cli() else { throw PageError(code: "cmux.page.unavailable", message: "no cmux CLI") }
        let (status, stdout, stderr) = try await runCLI(binary, arguments, ProcessInfo.processInfo.environment)
        // A refusal is the CLI's envelope on stderr (`code`, `message`): the page shows its words.
        return (try? JSONValue.parse(status == 0 ? stdout : stderr)) ?? .object([:])
    }

    nonisolated static func getArguments(_ agent: String) -> [String] {
        ["--json", "agent-config", "settings", "get", "--agent", agent]
    }

    /// The CLI's words for one `get`, `set` or `unset`. The key, value and scope are each their own
    /// argument after their flag; a key or scope starting with `-` is refused (the CLI would read it
    /// as a flag), a value may be anything (the CLI takes `--value` with a leading `-`).
    nonisolated static func arguments(_ params: JSONValue) throws -> [String] {
        let verb = params["verb"]?.stringValue ?? ""
        guard let agent = params["agent"]?.stringValue, agents.contains(agent) else {
            throw PageError.invalidParams("agent is claude or codex")
        }
        switch verb {
        case "get":
            return getArguments(agent)
        case "set", "unset":
            guard let key = params["key"]?.stringValue, isKey(key) else { throw PageError.invalidParams("key is a setting key") }
            var arguments = ["--json", "agent-config", "settings", verb, "--agent", agent, "--key", key]
            if verb == "set" {
                guard let value = params["value"]?.stringValue else { throw PageError.invalidParams("value is a string") }
                arguments += ["--value", value]
            }
            if let scope = params["scope"]?.stringValue {
                guard isScope(scope) else { throw PageError.invalidParams("scope is user, project, local or profile:NAME") }
                arguments += ["--scope", scope]
            }
            return arguments
        default:
            throw PageError.invalidParams("verb is get, set, unset or open")
        }
    }

    /// A dotted settings key (`model`, `permissions.defaultMode`, `env.FOO`): no flag, no control
    /// character, no space.
    nonisolated static func isKey(_ key: String) -> Bool {
        guard !key.isEmpty, key.count <= 256, !key.hasPrefix("-") else { return false }
        return key.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-:[]".unicodeScalars.contains(scalar))
        }
    }

    /// `user`, `project`, `local` or `profile:NAME` (a Codex profile's name).
    nonisolated static func isScope(_ scope: String) -> Bool {
        if ["user", "project", "local"].contains(scope) { return true }
        guard scope.hasPrefix("profile:") else { return false }
        let name = scope.dropFirst("profile:".count)
        guard !name.isEmpty, name.count <= 128, !name.hasPrefix("-") else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    /// Every `files[].path` a `get` answered.
    nonisolated static func listedFiles(_ state: JSONValue) -> Set<String> {
        guard case .array(let files)? = state["files"] else { return [] }
        return Set(files.compactMap { $0["path"]?.stringValue })
    }

    /// File I/O, off the main thread.
    @concurrent nonisolated static func fileExists(_ path: String) async -> Bool {
        FileManager.checked.fileExists(atPath: path)
    }

    /// The bundled CLI, off the main actor, with a deadline; a write runs to its end even when the
    /// page goes away, so an agent's file is never left half written by a closed page.
    @concurrent public nonisolated static func run(_ cli: URL, _ arguments: [String],
                                                   _ environment: [String: String]) async throws -> (Int32, Data, Data) {
        let request = ProcessRequest(cli, arguments, environment: environment, errorOutput: .separate,
                                     timeout: timeout, onCancel: .finish)
        let outcome = try await AsyncProcess().run(request)
        return (outcome.succeeded ? 0 : max(outcome.status, 1), outcome.output, outcome.errorOutput)
    }
}
