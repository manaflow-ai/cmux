import CMUXAgentLaunch
import Foundation

struct SessionEntry: Identifiable, Hashable, Sendable {
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
    /// Provider state root captured by the index, independent of transcript symlinks.
    let indexedCodexHome: String?
    let specifics: AgentSpecifics
    /// Session creation time when the source exposes it cheaply (file birth
    /// time, SQL column); nil otherwise.
    let created: Date?
    /// Exact conversation message count when it is knowable without extra
    /// scanning (whole file inside the metadata read cap, SQL count); nil when
    /// unknown or approximate.
    let messageCount: Int?

    init(
        id: String,
        agent: SessionAgent,
        sessionId: String,
        title: String,
        cwd: String?,
        gitBranch: String?,
        pullRequest: PullRequestLink?,
        modified: Date,
        fileURL: URL?,
        indexedCodexHome: String? = nil,
        specifics: AgentSpecifics,
        created: Date? = nil,
        messageCount: Int? = nil
    ) {
        self.id = id
        self.agent = agent
        self.sessionId = sessionId
        self.title = title
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.pullRequest = pullRequest
        self.modified = modified
        self.fileURL = fileURL
        self.indexedCodexHome = indexedCodexHome
        self.specifics = specifics
        self.created = created
        self.messageCount = messageCount
    }

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
            ),
            created: created,
            messageCount: messageCount
        )
    }

    /// Shell command exposed by the Copy Resume Command menu item.
    var copyResumeCommand: String? {
        guard let command = copyResumeCommandWithoutWorkingDirectory else { return nil }
        guard let cwd = resumeWorkingDirectory else {
            return command
        }
        return TerminalStartupWorkingDirectoryPrefix.prefix(command, workingDirectory: cwd)
    }

    private var copyResumeCommandWithoutWorkingDirectory: String? {
        switch specifics {
        case let .claude(model, permissionMode, configDirectoryForResume):
            // Route through the wrapper resolver token so a manually-resumed claude session
            // re-injects cmux hooks even when the command runs in a shell where the
            // integration's PATH shim / `claude()` function are not active (e.g. the
            // `$SHELL -lic` restore launcher). The token is POSIX-only and this command
            // is typed into — and copy-pasted into — the user's own shell (fish/csh
            // included), so the rendered command is wrapped in `/bin/sh -c '…'` to parse
            // everywhere; the `cd` guard stays outside in `copyResumeCommand`.
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
            // `copyResumeCommand`. https://github.com/manaflow-ai/cmux/issues/5639
            var parts = ["\(AgentResumeArgv.codexWrapperShellExecutableToken) resume \(sessionId)", AgentResumeArgv.codexUpdateCheckSuppressionOverride.joined(separator: " ")]
            if let model, !model.isEmpty {
                parts.append("-m \(Self.shellQuote(model))")
            }
            parts.append(contentsOf: Self.codexApprovalSandboxArgumentTokens(
                approvalPolicy: approval,
                sandboxMode: sandbox
            ).map(Self.shellQuote))
            if let effort, !effort.isEmpty {
                parts.append("-c model_reasoning_effort=\(Self.shellQuote(effort))")
            }
            return AgentResumeArgv.portableCodexResumeShellCommand(
                posixCommand: Self.withShellEnvironment(
                    codexHomeForResume.map { ["CODEX_HOME": $0] } ?? [:],
                    command: parts.joined(separator: " ")
                )
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
