import CmuxNextApps
import CmuxNextCodeRouter
import CmuxNextControl
import CmuxNextSettings
import Foundation

/// Owns the read side of the `agent_cli` family for this Mac.
///
/// The session host owns executable discovery. This first slice deliberately
/// reports only bounded, non-secret facts: whether a known binary is on PATH,
/// a display-only path label, and the account rows already produced by the
/// presence-only account detector. Version registries and visible-terminal
/// mutations remain unsupported until their job owner is wired in.
nonisolated struct AgentCLIAppOps: AppHostCapabilityHandler {
    let control: @Sendable (_ method: String, _ params: [String: JSONValue]) async throws(AppHostCapabilityError) -> JSONValue
    let environment: [String: String]
    let home: URL

    var families: Set<String> { ["agent_cli"] }

    init(control: @escaping @Sendable (_ method: String, _ params: [String: JSONValue]) async throws(AppHostCapabilityError) -> JSONValue,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.control = control
        self.environment = environment
        self.home = home
    }

    func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON {
        guard request.op == "agent_cli.list" else { throw .unsupported(request.op) }
        if let machine = request.params["machine"]?.stringValue, !machine.isEmpty, machine != "local" {
            throw AppHostCapabilityError(code: "machine.unavailable", message: "This Mac owns only the local agent CLI inventory.",
                                         details: ["machine": .string(machine)])
        }

        let accounts = try await control("accounts.list", ["origin": .string(request.origin)])
        return Self.list(accounts: AppJSON(accounts["providers"] ?? .array([])), environment: environment, home: home)
    }

    /// Pure inventory projection for tests and for the provider boundary.
    static func list(accounts: AppJSON, environment: [String: String], home: URL) -> AppJSON {
        let accountRows = Dictionary(uniqueKeysWithValues: (accounts.arrayValue ?? []).compactMap { row -> (String, AppJSON)? in
            guard let provider = row["provider"]?.stringValue else { return nil }
            return (provider, row)
        })
        let clis: [(id: String, name: String, binaries: [String], provider: String?)] = [
            ("claude", "Claude Code", ["claude"], "claude"),
            ("codex", "Codex", ["codex"], "codex"),
            ("opencode", "OpenCode", ["opencode"], nil),
            ("pi", "Pi", ["pi"], nil),
            ("chief", "Chief", ["chief"], nil),
            ("gemini", "Gemini CLI", ["gemini"], "gemini"),
            ("amp", "Amp", ["amp"], nil),
            ("copilot", "Copilot CLI", ["copilot"], "copilot"),
            ("cursor", "Cursor Agent", ["cursor-agent"], nil),
        ]
        let rows = clis.map { cli in
            let path = executablePath(names: cli.binaries, environment: environment)
            let account = cli.provider.flatMap { accountRows[$0] }.flatMap(Self.account)
            var row: [String: AppJSON] = [
                "cli": .string(cli.id),
                "name": .string(cli.name),
                "installed": .bool(path != nil),
                "version": .null,
                "latest": .null,
                "install_method": path.flatMap { installMethod(for: $0) }.map(AppJSON.string) ?? .null,
                "updatable": .bool(false),
                "accounts": account.map { .array([$0]) } ?? .array([]),
            ]
            if let path { row["path_label"] = .string(displayPath(path, home: home)) }
            return AppJSON.object(row)
        }
        return ["machine": .string("local"), "clis": .array(rows)]
    }

    private static func account(_ row: AppJSON) -> AppJSON? {
        guard let handle = row["account"]?.stringValue, let label = row["label"]?.stringValue else { return nil }
        var result: [String: AppJSON] = [
            "account": .string(handle),
            "label": .string(label),
            "status": row["status"]?.stringValue.map(AppJSON.string) ?? .string("unknown"),
        ]
        if let plan = row["plan"]?.stringValue { result["plan"] = .string(plan) }
        return .object(result)
    }

    private static func executablePath(names: [String], environment: [String: String]) -> String? {
        let components = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in components where !directory.isEmpty {
            for name in names {
                let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
        }
        return nil
    }

    private static func displayPath(_ path: String, home: URL) -> String {
        let homePath = home.standardizedFileURL.path
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        if normalized == homePath { return "~" }
        if normalized.hasPrefix(homePath + "/") { return "~" + normalized.dropFirst(homePath.count) }
        return normalized
    }

    private static func installMethod(for path: String) -> String? {
        if path.contains("/node_modules/") || path.contains("/.npm/") { return "npm" }
        if path.contains("/Cellar/") || path.contains("/homebrew/") { return "brew" }
        return "native"
    }
}