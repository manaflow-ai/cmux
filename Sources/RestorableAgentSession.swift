import Foundation

enum RestorableAgentKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case opencode

    private var hookStoreFilename: String {
        "\(rawValue)-hook-sessions.json"
    }

    func resumeCommand(
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?
    ) -> String? {
        AgentResumeCommandBuilder.resumeShellCommand(
            kind: self,
            sessionId: sessionId,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory
        )
    }

    func hookStoreFileURL(
        homeDirectory: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let directory: URL
        if let override = environment["CMUX_AGENT_HOOK_STATE_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            directory = URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
        } else {
            directory = URL(fileURLWithPath: homeDirectory, isDirectory: true)
                .appendingPathComponent(".cmuxterm", isDirectory: true)
        }
        return directory
            .appendingPathComponent(hookStoreFilename, isDirectory: false)
    }
}

struct AgentLaunchCommandSnapshot: Codable, Equatable, Sendable {
    var launcher: String?
    var executablePath: String?
    var arguments: [String]
    var workingDirectory: String?
    var environment: [String: String]?
    var capturedAt: TimeInterval?
    var source: String?
}

fileprivate func shellSingleQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private enum AgentResumeCommandBuilder {
    private static let claudeValueOptions: Set<String> = [
        "--add-dir",
        "--agent",
        "--agents",
        "--allowedTools",
        "--allowed-tools",
        "--append-system-prompt",
        "--betas",
        "--debug-file",
        "--disallowedTools",
        "--disallowed-tools",
        "--effort",
        "--fallback-model",
        "--file",
        "--fork-session",
        "--from-pr",
        "--input-format",
        "--json-schema",
        "--max-budget-usd",
        "--mcp-config",
        "--model",
        "--name",
        "-n",
        "--output-format",
        "--permission-mode",
        "--plugin-dir",
        "--remote-control-session-name-prefix",
        "--resume",
        "-r",
        "--session-id",
        "--setting-sources",
        "--settings",
        "--system-prompt",
        "--teammate-mode",
        "--tmux",
        "--tools",
        "--worktree",
        "-w"
    ]

    private static let claudeOptionalValueOptions: Set<String> = [
        "--debug"
    ]

    private static let claudeVariadicOptions: Set<String> = [
        "--add-dir",
        "--allowedTools",
        "--allowed-tools",
        "--betas",
        "--disallowedTools",
        "--disallowed-tools",
        "--file",
        "--mcp-config",
        "--tools"
    ]

    private static let claudeNonRestorableCommands: Set<String> = [
        "agents",
        "auth",
        "auto-mode",
        "api-key",
        "config",
        "doctor",
        "install",
        "mcp",
        "plugin",
        "plugins",
        "rc",
        "remote-control",
        "setup-token",
        "update",
        "upgrade"
    ]

    private static let codexValueOptions: Set<String> = [
        "--config",
        "-c",
        "--remote",
        "--remote-auth-token-env",
        "--image",
        "-i",
        "--model",
        "-m",
        "--local-provider",
        "--profile",
        "-p",
        "--sandbox",
        "-s",
        "--ask-for-approval",
        "-a",
        "--cd",
        "-C",
        "--add-dir",
        "--enable",
        "--disable"
    ]

    private static let codexNonRestorableCommands: Set<String> = [
        "exec",
        "e",
        "review",
        "login",
        "logout",
        "mcp",
        "mcp-server",
        "app-server",
        "app",
        "completion",
        "sandbox",
        "debug",
        "apply",
        "a",
        "fork",
        "cloud",
        "exec-server",
        "features",
        "help"
    ]

    private static let opencodeValueOptions: Set<String> = [
        "--log-level",
        "--port",
        "--hostname",
        "--mdns-domain",
        "--cors",
        "--model",
        "-m",
        "--session",
        "-s",
        "--prompt",
        "--agent"
    ]

    private static let opencodeNonRestorableCommands: Set<String> = [
        "completion",
        "acp",
        "mcp",
        "attach",
        "run",
        "debug",
        "providers",
        "auth",
        "agent",
        "upgrade",
        "uninstall",
        "serve",
        "web",
        "models",
        "stats",
        "export",
        "import",
        "pr",
        "github",
        "session",
        "plugin",
        "plug",
        "db"
    ]

    static func resumeShellCommand(
        kind: RestorableAgentKind,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?
    ) -> String? {
        guard !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let argv = resumeArguments(kind: kind, sessionId: sessionId, launchCommand: launchCommand),
              !argv.isEmpty else {
            return nil
        }

        var commandParts: [String] = []
        if let env = launchCommand?.environment, !env.isEmpty {
            var environmentParts: [String] = []
            for key in env.keys.sorted() {
                guard isSafeEnvironmentKey(key),
                      let value = sanitizedEnvironmentValue(key: key, value: env[key]) else { continue }
                environmentParts.append("\(key)=\(value)")
            }
            if !environmentParts.isEmpty {
                commandParts.append("env")
                commandParts.append(contentsOf: environmentParts)
            }
        }
        commandParts.append(contentsOf: argv)

        var shellCommand = commandParts.map(shellSingleQuoted).joined(separator: " ")
        let cwd = normalized(workingDirectory ?? launchCommand?.workingDirectory)
        if let cwd {
            shellCommand = "cd \(shellSingleQuoted(cwd)) && \(shellCommand)"
        }
        return shellCommand
    }

    private static func resumeArguments(
        kind: RestorableAgentKind,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?
    ) -> [String]? {
        switch launchCommand?.launcher {
        case "claudeTeams":
            let original = commandParts(
                launchCommand: launchCommand,
                fallbackExecutable: "cmux"
            )
            var args = original.tail
            if args.first == "claude-teams" {
                args.removeFirst()
            }
            guard let preserved = preservedClaudeArguments(args) else { return nil }
            return [original.executable, "claude-teams", "--resume", sessionId] + preserved
        case "omo":
            let original = commandParts(
                launchCommand: launchCommand,
                fallbackExecutable: "cmux"
            )
            var args = original.tail
            if args.first == "omo" {
                args.removeFirst()
            }
            guard let preserved = preservedOpenCodeArguments(args) else { return nil }
            return [original.executable, "omo", "--session", sessionId] + preserved
        case "omx", "omc":
            return nil
        default:
            break
        }

        switch kind {
        case .claude:
            let original = commandParts(launchCommand: launchCommand, fallbackExecutable: "claude")
            guard let preserved = preservedClaudeArguments(original.tail) else { return nil }
            return [original.executable, "--resume", sessionId] + preserved
        case .codex:
            let original = commandParts(launchCommand: launchCommand, fallbackExecutable: "codex")
            guard let preserved = preservedCodexArguments(original.tail) else { return nil }
            return [original.executable, "resume"] + preserved + [sessionId]
        case .opencode:
            let original = commandParts(launchCommand: launchCommand, fallbackExecutable: "opencode")
            guard let preserved = preservedOpenCodeArguments(original.tail) else { return nil }
            return [original.executable, "--session", sessionId] + preserved
        }
    }

    private static func commandParts(
        launchCommand: AgentLaunchCommandSnapshot?,
        fallbackExecutable: String
    ) -> (executable: String, tail: [String]) {
        let arguments = launchCommand?.arguments ?? []
        let executable = normalized(launchCommand?.executablePath)
            ?? arguments.first
            ?? fallbackExecutable
        let tail = arguments.isEmpty ? [] : Array(arguments.dropFirst())
        return (executable, tail)
    }

    private static func preservedClaudeArguments(_ args: [String]) -> [String]? {
        preserveOptions(
            args,
            valueOptions: claudeValueOptions,
            optionalValueOptions: claudeOptionalValueOptions,
            variadicOptions: claudeVariadicOptions,
            nonRestorableCommands: claudeNonRestorableCommands,
            droppedOptions: [
                "--continue",
                "-c",
                "--fork-session",
                "--from-pr",
                "--resume",
                "-r",
                "--session-id",
                "--tmux",
                "--worktree",
                "-w"
            ],
            droppedOptionPrefixes: [
                "--fork-session=",
                "--from-pr=",
                "--resume=",
                "--session-id=",
                "--tmux=",
                "--worktree="
            ],
            rejectOptions: [
                "--print",
                "-p",
                "--no-session-persistence"
            ],
            skipHookSettings: true,
            resumeSubcommand: nil
        )
    }

    private static func preservedCodexArguments(_ args: [String]) -> [String]? {
        preserveOptions(
            args,
            valueOptions: codexValueOptions,
            optionalValueOptions: [],
            variadicOptions: ["--image", "-i", "--add-dir"],
            nonRestorableCommands: codexNonRestorableCommands,
            droppedOptions: [
                "--last",
                "--all"
            ],
            droppedOptionPrefixes: [],
            rejectOptions: [],
            skipHookSettings: false,
            resumeSubcommand: "resume"
        )
    }

    private static func preservedOpenCodeArguments(_ args: [String]) -> [String]? {
        let sanitizedArgs = args.filter { !isOpenCodeInternalWorkerArgument($0) }
        return preserveOptions(
            sanitizedArgs,
            valueOptions: opencodeValueOptions,
            optionalValueOptions: [],
            variadicOptions: ["--cors"],
            nonRestorableCommands: opencodeNonRestorableCommands,
            droppedOptions: [
                "--continue",
                "-c",
                "--fork",
                "--session",
                "-s",
                "--prompt"
            ],
            droppedOptionPrefixes: [
                "--session=",
                "--prompt="
            ],
            rejectOptions: [],
            skipHookSettings: false,
            resumeSubcommand: nil,
            preserveFirstPositional: true
        )
    }

    private static func isOpenCodeInternalWorkerArgument(_ value: String) -> Bool {
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        return normalized.contains("/$bunfs/") &&
            normalized.contains("/src/cli/cmd/tui/worker.js")
    }

    private static func preserveOptions(
        _ args: [String],
        valueOptions: Set<String>,
        optionalValueOptions: Set<String>,
        variadicOptions: Set<String>,
        nonRestorableCommands: Set<String>,
        droppedOptions: Set<String>,
        droppedOptionPrefixes: [String],
        rejectOptions: Set<String>,
        skipHookSettings: Bool,
        resumeSubcommand: String?,
        preserveFirstPositional: Bool = false
    ) -> [String]? {
        var result: [String] = []
        var index = 0
        var consumedFirstPositional = false
        var skippingResumePositionals = false

        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                break
            }

            if !arg.hasPrefix("-") || arg == "-" {
                if let resumeSubcommand, arg == resumeSubcommand {
                    skippingResumePositionals = true
                    index += 1
                    continue
                }
                if skippingResumePositionals {
                    break
                }
                if nonRestorableCommands.contains(arg) {
                    return nil
                }
                if preserveFirstPositional && !consumedFirstPositional {
                    result.append(arg)
                    consumedFirstPositional = true
                    index += 1
                    continue
                }
                break
            }

            if shouldDropOption(arg, droppedOptions: rejectOptions) {
                return nil
            }

            if droppedOptionPrefixes.contains(where: { arg.hasPrefix($0) }) {
                index += 1
                continue
            }

            if shouldDropOption(arg, droppedOptions: droppedOptions) {
                index += optionWidth(
                    args,
                    index: index,
                    valueOptions: valueOptions,
                    optionalValueOptions: optionalValueOptions,
                    variadicOptions: variadicOptions
                )
                continue
            }

            if skipHookSettings, isHookSettingsOption(args, index: index) {
                index += optionWidth(
                    args,
                    index: index,
                    valueOptions: valueOptions,
                    optionalValueOptions: optionalValueOptions,
                    variadicOptions: variadicOptions
                )
                continue
            }

            let width = optionWidth(
                args,
                index: index,
                valueOptions: valueOptions,
                optionalValueOptions: optionalValueOptions,
                variadicOptions: variadicOptions
            )
            result.append(contentsOf: args[index..<min(args.count, index + width)])
            index += width
        }

        return result
    }

    private static func shouldDropOption(_ arg: String, droppedOptions: Set<String>) -> Bool {
        if droppedOptions.contains(arg) { return true }
        guard let equals = arg.firstIndex(of: "=") else { return false }
        return droppedOptions.contains(String(arg[..<equals]))
    }

    private static func optionWidth(
        _ args: [String],
        index: Int,
        valueOptions: Set<String>,
        optionalValueOptions: Set<String>,
        variadicOptions: Set<String>
    ) -> Int {
        let arg = args[index]
        if arg.contains("=") {
            return 1
        }
        if optionalValueOptions.contains(arg) {
            guard index + 1 < args.count,
                  looksLikeOptionalValue(
                    args[index + 1],
                    following: index + 2 < args.count ? args[index + 2] : nil
                  ) else {
                return 1
            }
            return 2
        }
        guard valueOptions.contains(arg), index + 1 < args.count else {
            return 1
        }
        if variadicOptions.contains(arg) {
            var end = index + 1
            while end < args.count, !args[end].hasPrefix("-") {
                end += 1
            }
            return max(1, end - index)
        }
        return 2
    }

    private static func looksLikeOptionalValue(_ value: String, following: String?) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("-"),
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return false
        }
        return value.contains(",") || (following?.hasPrefix("-") == true)
    }

    private static func isHookSettingsOption(_ args: [String], index: Int) -> Bool {
        let arg = args[index]
        if arg.hasPrefix("--settings=") {
            return arg.contains("claude-hook") || arg.contains("hooks claude")
        }
        guard arg == "--settings", index + 1 < args.count else {
            return false
        }
        return args[index + 1].contains("claude-hook") || args[index + 1].contains("hooks claude")
    }

    private static func isSafeEnvironmentKey(_ key: String) -> Bool {
        switch key {
        case "ANTHROPIC_MODEL",
             "CLAUDE_CONFIG_DIR",
             "CMUX_CUSTOM_CLAUDE_PATH",
             "CODEX_HOME",
             "NODE_OPTIONS",
             "OPENCODE_CONFIG_DIR":
            return true
        default:
            return false
        }
    }

    private static func sanitizedEnvironmentValue(key: String, value: String?) -> String? {
        guard key == "NODE_OPTIONS" else {
            return value
        }
        return sanitizedNodeOptions(value)
    }

    private static func sanitizedNodeOptions(_ rawValue: String?) -> String? {
        let tokens = rawValue?
            .split(whereSeparator: \.isWhitespace)
            .map(String.init) ?? []
        guard !tokens.isEmpty else { return nil }

        var sanitized: [String] = []
        var index = 0
        var shouldDropInjectedHeapCap = false
        while index < tokens.count {
            let token = tokens[index]

            if shouldDropInjectedHeapCap, isInjectedNodeHeapCap(tokens, index: index) {
                index += nodeHeapCapWidth(tokens, index: index)
                shouldDropInjectedHeapCap = false
                continue
            }
            shouldDropInjectedHeapCap = false

            if isRequireOption(token), index + 1 < tokens.count,
               isCmuxNodeOptionsRestoreModulePath(tokens[index + 1]) {
                index += 2
                shouldDropInjectedHeapCap = true
                continue
            }
            if let path = inlineRequireOptionPath(token),
               isCmuxNodeOptionsRestoreModulePath(path) {
                index += 1
                shouldDropInjectedHeapCap = true
                continue
            }

            sanitized.append(token)
            index += 1
        }

        let joined = sanitized.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func isRequireOption(_ token: String) -> Bool {
        token == "--require" || token == "-r"
    }

    private static func inlineRequireOptionPath(_ token: String) -> String? {
        for prefix in ["--require=", "-r="] where token.hasPrefix(prefix) {
            return String(token.dropFirst(prefix.count))
        }
        return nil
    }

    private static func isCmuxNodeOptionsRestoreModulePath(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        guard URL(fileURLWithPath: trimmed).lastPathComponent == "restore-node-options.cjs" else {
            return false
        }
        return trimmed.contains("/cmux-")
    }

    private static func isInjectedNodeHeapCap(_ tokens: [String], index: Int) -> Bool {
        guard index < tokens.count else { return false }
        let token = tokens[index]
        if token == "--max-old-space-size" {
            return index + 1 < tokens.count && tokens[index + 1] == "4096"
        }
        return token == "--max-old-space-size=4096"
    }

    private static func nodeHeapCapWidth(_ tokens: [String], index: Int) -> Int {
        guard index < tokens.count else { return 1 }
        return tokens[index] == "--max-old-space-size" ? min(2, tokens.count - index) : 1
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

struct SessionRestorableAgentSnapshot: Codable, Sendable {
    static let maxInlineStartupInputBytes = 900

    var kind: RestorableAgentKind
    var sessionId: String
    var workingDirectory: String?
    var launchCommand: AgentLaunchCommandSnapshot?

    var resumeCommand: String? {
        kind.resumeCommand(
            sessionId: sessionId,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory
        )
    }

    func resumeStartupInput(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> String? {
        guard let command = resumeCommand else { return nil }

        let inlineInput = command + "\n"
        guard inlineInput.utf8.count > Self.maxInlineStartupInputBytes else {
            return inlineInput
        }
        guard let scriptURL = AgentResumeScriptStore.writeLauncherScript(
            command: command,
            kind: kind,
            sessionId: sessionId,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory
        ) else {
            return nil
        }

        let scriptInput = "/bin/zsh \(shellSingleQuoted(scriptURL.path))\n"
        return scriptInput.utf8.count <= Self.maxInlineStartupInputBytes ? scriptInput : nil
    }
}

private enum AgentResumeScriptStore {
    private static let directoryName = "cmux-agent-resume"
    private static let scriptTTL: TimeInterval = 24 * 60 * 60

    static func writeLauncherScript(
        command: String,
        kind: RestorableAgentKind,
        sessionId: String,
        fileManager: FileManager,
        temporaryDirectory: URL
    ) -> URL? {
        let directoryURL = temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
            pruneOldScripts(in: directoryURL, fileManager: fileManager)

            let safeSessionPrefix = sessionId
                .prefix(12)
                .map { character -> Character in
                    character.isLetter || character.isNumber || character == "-" ? character : "_"
                }
            let scriptURL = directoryURL.appendingPathComponent(
                "\(kind.rawValue)-\(String(safeSessionPrefix))-\(UUID().uuidString).zsh",
                isDirectory: false
            )
            let contents = """
            #!/bin/zsh
            rm -f -- "$0" 2>/dev/null || true
            \(command)
            """
            try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scriptURL.path)
            return scriptURL
        } catch {
            return nil
        }
    }

    private static func pruneOldScripts(in directoryURL: URL, fileManager: FileManager) {
        guard let scriptURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-scriptTTL)
        for scriptURL in scriptURLs where scriptURL.pathExtension == "zsh" {
            let values = try? scriptURL.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < cutoff {
                try? fileManager.removeItem(at: scriptURL)
            }
        }
    }
}

private struct RestorableAgentHookSessionRecord: Codable, Sendable {
    var sessionId: String
    var workspaceId: String
    var surfaceId: String
    var cwd: String?
    var launchCommand: AgentLaunchCommandSnapshot?
    var updatedAt: TimeInterval
}

private struct RestorableAgentHookSessionStoreFile: Codable, Sendable {
    var version: Int = 1
    var sessions: [String: RestorableAgentHookSessionRecord] = [:]
}

struct RestorableAgentSessionIndex: Sendable {
    static let empty = RestorableAgentSessionIndex(snapshotsByPanel: [:])

    private struct PanelKey: Hashable, Sendable {
        let workspaceId: UUID
        let panelId: UUID
    }

    private let snapshotsByPanel: [PanelKey: SessionRestorableAgentSnapshot]

    func snapshot(workspaceId: UUID, panelId: UUID) -> SessionRestorableAgentSnapshot? {
        snapshotsByPanel[PanelKey(workspaceId: workspaceId, panelId: panelId)]
    }

    static func load(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> RestorableAgentSessionIndex {
        let decoder = JSONDecoder()
        var resolved: [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval)] = [:]

        for kind in RestorableAgentKind.allCases {
            let fileURL = kind.hookStoreFileURL(homeDirectory: homeDirectory)
            guard fileManager.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL),
                  let state = try? decoder.decode(RestorableAgentHookSessionStoreFile.self, from: data) else {
                continue
            }

            for record in state.sessions.values {
                let normalizedSessionId = record.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedSessionId.isEmpty,
                      let workspaceId = UUID(uuidString: record.workspaceId),
                      let panelId = UUID(uuidString: record.surfaceId) else {
                    continue
                }

                let snapshot = SessionRestorableAgentSnapshot(
                    kind: kind,
                    sessionId: normalizedSessionId,
                    workingDirectory: normalizedWorkingDirectory(record.cwd),
                    launchCommand: record.launchCommand
                )
                let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
                if let existing = resolved[key], existing.updatedAt > record.updatedAt {
                    continue
                }
                resolved[key] = (snapshot: snapshot, updatedAt: record.updatedAt)
            }
        }

        return RestorableAgentSessionIndex(snapshotsByPanel: resolved.mapValues(\.snapshot))
    }

    private static func normalizedWorkingDirectory(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }

    private init(snapshotsByPanel: [PanelKey: SessionRestorableAgentSnapshot]) {
        self.snapshotsByPanel = snapshotsByPanel
    }
}
