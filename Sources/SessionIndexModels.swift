import CMUXAgentLaunch
import Foundation

// MARK: - Agents

struct RegisteredSessionAgent: Hashable, Sendable {
    let id: String
    let name: String?
    let iconAssetName: String?

    init(id: String, name: String? = nil, iconAssetName: String? = nil) {
        self.id = id
        self.name = Self.normalizedOptional(name)
        self.iconAssetName = Self.normalizedOptional(iconAssetName)
    }

    init(registration: CmuxVaultAgentRegistration) {
        self.init(id: registration.id, name: registration.name, iconAssetName: registration.iconAssetName)
    }

    var displayName: String {
        if let name {
            return name
        }
        if id == "pi" {
            return "Pi"
        }
        return id
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

enum SessionAgent: Identifiable, Codable, Sendable, Hashable {
    case claude
    case codex
    case grok
    case opencode
    case rovodev
    case hermesAgent
    case registered(RegisteredSessionAgent)

    var id: String { rawValue }

    static let builtInCases: [SessionAgent] = [.claude, .codex, .grok, .opencode, .rovodev, .hermesAgent]

    init?(rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "claude": self = .claude
        case "codex": self = .codex
        case "grok": self = .grok
        case "opencode": self = .opencode
        case "rovodev": self = .rovodev
        case "hermes-agent": self = .hermesAgent
        default:
            guard CmuxVaultAgentRegistration.isValidID(value) else { return nil }
            self = .registered(RegisteredSessionAgent(id: value))
        }
    }

    var rawValue: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .grok: return "grok"
        case .opencode: return "opencode"
        case .rovodev: return "rovodev"
        case .hermesAgent: return "hermes-agent"
        case .registered(let agent): return agent.id
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, iconAssetName
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           container.contains(.id) {
            let id = try container.decode(String.self, forKey: .id)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = try container.decodeIfPresent(String.self, forKey: .name)
            let iconAssetName = try container.decodeIfPresent(String.self, forKey: .iconAssetName)
            let hasRegisteredMetadata = name != nil || iconAssetName != nil
            if let builtIn = SessionAgent(rawValue: id),
               (!CmuxVaultAgentRegistration.isValidID(id) || SessionAgent.builtInCases.contains(builtIn)),
               !hasRegisteredMetadata {
                self = builtIn
                return
            }
            guard CmuxVaultAgentRegistration.isValidID(id) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .id,
                    in: container,
                    debugDescription: "Invalid session agent '\(id)'"
                )
            }
            self = .registered(RegisteredSessionAgent(
                id: id,
                name: name,
                iconAssetName: iconAssetName
            ))
            return
        }

        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let agent = SessionAgent(rawValue: value) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid session agent '\(value)'"
                )
            )
        }
        self = agent
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .registered(let agent):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(agent.id, forKey: .id)
            try container.encodeIfPresent(agent.name, forKey: .name)
            try container.encodeIfPresent(agent.iconAssetName, forKey: .iconAssetName)
        default:
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }
}

enum OpenCodeDatabaseSnapshot {
    struct Snapshot {
        let databaseURL: URL
        private let directoryURL: URL

        init(databaseURL: URL, directoryURL: URL) {
            self.databaseURL = databaseURL
            self.directoryURL = directoryURL
        }

        func remove() {
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }

    private static let sourcePath = ("~/.local/share/opencode/opencode.db" as NSString).expandingTildeInPath

    static func make(prefix: String) throws -> Snapshot? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourcePath) else { return nil }

        let snapshotDir = fileManager.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: snapshotDir, withIntermediateDirectories: true)

        let snapshotDB = snapshotDir.appendingPathComponent("opencode.db")
        do {
            try fileManager.copyItem(atPath: sourcePath, toPath: snapshotDB.path)
        } catch {
            try? fileManager.removeItem(at: snapshotDir)
            throw error
        }

        do {
            for sidecar in ["-wal", "-shm"] {
                let source = sourcePath + sidecar
                let destination = snapshotDB.path + sidecar
                if fileManager.fileExists(atPath: source) {
                    try fileManager.copyItem(atPath: source, toPath: destination)
                }
            }
        } catch {
            try? fileManager.removeItem(at: snapshotDir)
            throw error
        }

        return Snapshot(databaseURL: snapshotDB, directoryURL: snapshotDir)
    }
}

// MARK: - Session entry

struct PullRequestLink: Hashable {
    let number: Int
    let url: String
    let repository: String?
}

/// Agent-specific fields used to build the resume command with appropriate flags.
enum AgentSpecifics: Hashable {
    case claude(model: String?, permissionMode: String?, configDirectoryForResume: String?)
    case codex(model: String?, approvalPolicy: String?, sandboxMode: String?, effort: String?)
    case grok(model: String?, permissionMode: String?, sandboxMode: String?, grokHome: String?)
    case opencode(providerModel: String?, agentName: String?)
    case rovodev
    case hermesAgent(source: String?, model: String?, hermesHome: String?)
    case registered(CmuxVaultAgentRegistration)
}

enum ClaudeConfigurationRoot {
    nonisolated static func configuredResumeDirectory(
        _ configDir: String,
        fileManager: FileManager = .default
    ) -> String? {
        let preferredConfigDir = ClaudeConfigDirectoryPath.preferredPath(
            configDir,
            fileManager: fileManager
        )
        guard isLikelyConfigured(preferredConfigDir, fileManager: fileManager) else {
            return nil
        }
        return preferredConfigDir
    }

    nonisolated static func isLikelyConfigured(
        _ configDir: String,
        fileManager: FileManager = .default
    ) -> Bool {
        let configPath = ((configDir as NSString).expandingTildeInPath as NSString)
            .appendingPathComponent(".claude.json")
        guard let data = fileManager.contents(atPath: configPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return hasConfiguredAuthValue(obj["oauthAccount"])
            || hasConfiguredAuthValue(obj["primaryApiKey"])
            || hasConfiguredAuthValue(obj["apiKey"])
    }

    private nonisolated static func hasConfiguredAuthValue(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else {
            return false
        }
        if let string = value as? String {
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let dictionary = value as? [String: Any] {
            return !dictionary.isEmpty
        }
        if let array = value as? [Any] {
            return !array.isEmpty
        }
        return true
    }
}

struct SessionEntry: Identifiable, Hashable {
    let id: String
    let agent: SessionAgent
    /// Native session identifier for the agent's CLI (used to build the resume command).
    let sessionId: String
    let title: String
    let cwd: String?
    let gitBranch: String?
    let pullRequest: PullRequestLink?
    let modified: Date
    let fileURL: URL?
    let specifics: AgentSpecifics

    var resumeWorkingDirectory: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        if case .registered(let registration) = specifics,
           registration.cwd == .ignore {
            return nil
        }
        return cwd
    }

    func withClaudeConfigDirectoryForResume(_ configDirectory: String?) -> SessionEntry {
        guard case let .claude(model, permissionMode, currentConfigDirectory) = specifics,
              currentConfigDirectory != configDirectory else {
            return self
        }
        return SessionEntry(
            id: id,
            agent: agent,
            sessionId: sessionId,
            title: title,
            cwd: cwd,
            gitBranch: gitBranch,
            pullRequest: pullRequest,
            modified: modified,
            fileURL: fileURL,
            specifics: .claude(
                model: model,
                permissionMode: permissionMode,
                configDirectoryForResume: configDirectory
            )
        )
    }

    /// Shell command that resumes this session in a new terminal, with the agent's
    /// known per-session settings injected as CLI flags.
    var resumeCommand: String? {
        resumeCommandWithCwd
    }

    /// Shell command that resumes this session after guarding the launch directory.
    var resumeCommandWithCwd: String? {
        guard let command = resumeCommandWithoutWorkingDirectory else { return nil }
        guard let cwd = resumeWorkingDirectory else {
            return command
        }
        return TerminalStartupWorkingDirectoryPrefix.prefix(command, workingDirectory: cwd)
    }

    private var resumeCommandWithoutWorkingDirectory: String? {
        switch specifics {
        case let .claude(model, permissionMode, configDirectoryForResume):
            // Route through the wrapper resolver token so a manually-resumed claude session
            // re-injects cmux hooks even when the command runs in a shell where the
            // integration's PATH shim / `claude()` function are not active (e.g. the
            // `$SHELL -lic` restore launcher). The token is POSIX-only and this command
            // is typed into — and copy-pasted into — the user's own shell (fish/csh
            // included), so the rendered command is wrapped in `/bin/sh -c '…'` to parse
            // everywhere; the `cd` guard stays outside in `resumeCommandWithCwd`.
            // https://github.com/manaflow-ai/cmux/issues/5639
            var parts = ["\(AgentResumeArgv.claudeWrapperShellExecutableToken) --resume \(sessionId)"]
            if let model, !model.isEmpty {
                parts.append("--model \(Self.shellQuote(model))")
            }
            if let permissionMode, !permissionMode.isEmpty {
                parts.append("--permission-mode \(Self.shellQuote(permissionMode))")
            }
            let environment = configDirectoryForResume.map {
                ["CLAUDE_CONFIG_DIR": $0, "CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV": "1", "CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS": "CLAUDE_CONFIG_DIR"]
            } ?? [:]
            return AgentResumeArgv.portableClaudeResumeShellCommand(
                posixCommand: Self.withShellEnvironment(environment, command: parts.joined(separator: " "))
            )
        case let .codex(model, approval, sandbox, effort):
            // Route through the codex wrapper-resolver token so a manually- or
            // auto-resumed codex session re-injects cmux hooks even when the
            // command runs in a shell where the integration's PATH shim is not
            // active (e.g. the `$SHELL -lic` restore launcher). Without this the
            // bare `codex resume <id>` resolves to the real codex binary,
            // bypassing cmux-codex-wrapper, so no SessionStart fires and the iOS
            // GUI stays read-only. Mirror of the claude case: the token is
            // POSIX-only and this command is typed into / copy-pasted into the
            // user's own shell (fish/csh included), so the rendered command is
            // wrapped in `/bin/sh -c '…'`; the `cd` guard stays outside in
            // `resumeCommandWithCwd`. https://github.com/manaflow-ai/cmux/issues/5639
            var parts = ["\(AgentResumeArgv.codexWrapperShellExecutableToken) resume \(sessionId)"]
            parts.append(AgentResumeArgv.codexUpdateCheckSuppressionOverride.joined(separator: " "))
            if let model, !model.isEmpty {
                parts.append("-m \(Self.shellQuote(model))")
            }
            parts.append(contentsOf: Self.codexApprovalSandboxArguments(
                approvalPolicy: approval,
                sandboxMode: sandbox
            ))
            if let effort, !effort.isEmpty {
                parts.append("-c model_reasoning_effort=\(Self.shellQuote(effort))")
            }
            return AgentResumeArgv.portableCodexResumeShellCommand(
                posixCommand: parts.joined(separator: " ")
            )
        case let .grok(model, permissionMode, sandboxMode, grokHome):
            var argv = ["grok", "-r", sessionId]
            if let model, !model.isEmpty {
                argv.append(contentsOf: ["-m", model])
            }
            if let permissionMode, !permissionMode.isEmpty {
                argv.append(contentsOf: ["--permission-mode", permissionMode])
            }
            if let sandboxMode, !sandboxMode.isEmpty {
                argv.append(contentsOf: ["--sandbox", sandboxMode])
            }
            let environment = grokHome.flatMap { value -> [String: String]? in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : ["GROK_HOME": trimmed]
            } ?? [:]
            return Self.singleQuotedShellCommand(environment: environment, argv: argv)
        case let .opencode(providerModel, agentName):
            var parts = ["opencode --session \(sessionId)"]
            if let providerModel, !providerModel.isEmpty {
                parts.append("-m \(Self.shellQuote(providerModel))")
            }
            if let agentName, !agentName.isEmpty {
                parts.append("--agent \(Self.shellQuote(agentName))")
            }
            return parts.joined(separator: " ")
        case .rovodev:
            return "acli rovodev run --restore \(Self.shellQuote(sessionId))"
        case let .hermesAgent(source, model, hermesHome):
            return Self.hermesResumeCommand(
                sessionId: sessionId,
                source: source,
                model: model,
                hermesHome: hermesHome
            )
        case .registered(let registration):
            if let command = AgentResumeCommandBuilder.resumeShellCommand(
                kind: .custom(registration.id),
                sessionId: sessionId,
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: registration.id,
                    executablePath: nil,
                    arguments: [registration.defaultExecutable],
                    workingDirectory: resumeWorkingDirectory,
                    environment: nil,
                    capturedAt: nil,
                    source: "vault"
                ),
                workingDirectory: resumeWorkingDirectory,
                registrationOverride: registration,
                includeWorkingDirectoryPrefix: false
            ) {
                return command
            }
            return nil
        }
    }

    private static func withShellEnvironment(
        _ environment: [String: String],
        command: String
    ) -> String {
        let assignments = environment
            .filter { key, _ in
                key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
            }
            .sorted { $0.key < $1.key }
            .map { key, value in "\(key)=\(shellQuote(value))" }
        guard !assignments.isEmpty else { return command }
        return "env \(assignments.joined(separator: " ")) \(command)"
    }

    private static func singleQuotedShellCommand(
        environment: [String: String],
        argv: [String]
    ) -> String {
        var parts: [String] = []
        let assignments = environment
            .filter { key, _ in
                key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
            }
            .sorted { $0.key < $1.key }
            .map { key, value in "\(key)=\(value)" }
        if !assignments.isEmpty {
            parts.append("env")
            parts.append(contentsOf: assignments)
        }
        parts.append(contentsOf: argv)
        return parts.map(Self.shellSingleQuote).joined(separator: " ")
    }

    private static func shellSingleQuote(_ value: String) -> String {
        TerminalStartupShellQuoting.singleQuoted(value)
    }

    /// Single-quote a value for safe shell injection. Escapes embedded single quotes.
    static func shellQuote(_ value: String) -> String {
        TerminalStartupShellQuoting.shellToken(value, allowingBareASCII: true)
    }

    /// Sandbox-policy values the Codex CLI `--sandbox` flag accepts.
    ///
    /// cmux captures Codex's *internal* sandbox-policy `type`, which is a
    /// superset of the CLI vocabulary (it also includes `disabled`, `managed`,
    /// and may grow further). Those extra types have no `--sandbox` equivalent
    /// and must never be forwarded as `-s`, or Codex rejects the resumed command
    /// (see https://github.com/manaflow-ai/cmux/issues/5262).
    static let codexCLISandboxModes: Set<String> = [
        "read-only",
        "workspace-write",
        "danger-full-access",
    ]

    /// Builds the approval/sandbox CLI tokens for a `codex resume` command from
    /// the per-session policy cmux captured, always yielding a valid invocation.
    ///
    /// A `--dangerously-bypass-approvals-and-sandbox` launch round-trips to a
    /// captured `(approval: "never", sandbox: "disabled")`. This reproduces that
    /// single combined flag rather than the invalid, contradictory `-a never -s
    /// disabled`. Sandbox types with no CLI equivalent (`disabled`, `managed`,
    /// future values) are dropped instead of emitted as an invalid `-s`; valid
    /// values pass through unchanged.
    static func codexApprovalSandboxArguments(
        approvalPolicy: String?,
        sandboxMode: String?
    ) -> [String] {
        // The exact inverse of `--dangerously-bypass-approvals-and-sandbox`:
        // emit that one flag and nothing else, since `-a`/`-s` here would be both
        // invalid (`-s disabled`) and contradictory with the bypass flag.
        if approvalPolicy == "never", sandboxMode == "disabled" {
            return ["--dangerously-bypass-approvals-and-sandbox"]
        }

        var parts: [String] = []
        if let approvalPolicy, !approvalPolicy.isEmpty {
            parts.append("-a \(shellQuote(approvalPolicy))")
        }
        if let sandboxMode, !sandboxMode.isEmpty, codexCLISandboxModes.contains(sandboxMode) {
            parts.append("-s \(shellQuote(sandboxMode))")
        }
        return parts
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if agent == .claude {
            if let title = Self.claudeDisplayTitle(from: trimmed) {
                return title
            }
            if Self.isClaudeLocalCommandEnvelope(trimmed) {
                return String(localized: "sessionIndex.localCommand", defaultValue: "Local command")
            }
            if Self.isClaudeSyntheticEnvelope(trimmed) {
                return String(localized: "sessionIndex.untitled", defaultValue: "Untitled chat")
            }
        }
        if trimmed.isEmpty {
            return String(localized: "sessionIndex.untitled", defaultValue: "Untitled chat")
        }
        return trimmed
    }

    static func claudeDisplayTitle(from raw: String, isMeta: Bool = false) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isMeta || isClaudeSyntheticEnvelope(trimmed) {
            return nil
        }
        if let commandTitle = claudeSlashCommandTitle(from: trimmed) {
            return commandTitle
        }
        return trimmed
    }

    private static func claudeSlashCommandTitle(from raw: String) -> String? {
        let commandName = claudeTagValue("command-name", in: raw)
        let commandMessage = claudeTagValue("command-message", in: raw)
        var parts: [String] = []
        if let commandName {
            parts.append(commandName)
        }
        if let commandMessage,
           !isDuplicateClaudeCommandMessage(commandMessage, commandName: commandName) {
            parts.append(commandMessage)
        }
        if let args = claudeTagValue("command-args", in: raw) {
            parts.append(args)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func isDuplicateClaudeCommandMessage(_ message: String, commandName: String?) -> Bool {
        guard let commandName else { return false }
        let commandWithoutSlash = commandName.hasPrefix("/")
            ? String(commandName.dropFirst())
            : commandName
        return message.caseInsensitiveCompare(commandName) == .orderedSame
            || message.caseInsensitiveCompare(commandWithoutSlash) == .orderedSame
    }

    private static func claudeTagValue(_ tag: String, in raw: String) -> String? {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard let start = raw.range(of: open),
              let end = raw.range(of: close, range: start.upperBound..<raw.endIndex) else {
            return nil
        }
        let value = String(raw[start.upperBound..<end.lowerBound])
        let collapsed = collapseWhitespace(value)
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func isClaudeSyntheticEnvelope(_ raw: String) -> Bool {
        isClaudeLocalCommandEnvelope(raw)
            || raw.hasPrefix("<system-reminder>")
    }

    private static func isClaudeLocalCommandEnvelope(_ raw: String) -> Bool {
        raw.hasPrefix("<local-command-")
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    var cwdLabel: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let home = NSHomeDirectory()
        // Compare on a path boundary so /Users/al doesn't get matched by a
        // home of /Users/alice (would render as "~ice/foo").
        if cwd == home {
            return "~"
        }
        if cwd.hasPrefix(home + "/") {
            return "~" + cwd.dropFirst(home.count)
        }
        return cwd
    }

    var cwdBasename: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return (cwd as NSString).lastPathComponent
    }
}
