import CMUXAgentLaunch
import Foundation

// MARK: - Agents

enum SessionAgent: Identifiable, Hashable, Codable, Sendable {
    case claude
    case codex
    case opencode
    case rovodev
    case registered(String)

    var id: String { rawValue }

    static let builtInCases: [SessionAgent] = [.claude, .codex, .opencode, .rovodev]

    init?(rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "claude": self = .claude
        case "codex": self = .codex
        case "opencode": self = .opencode
        case "rovodev": self = .rovodev
        default:
            guard CmuxVaultAgentRegistration.isValidID(value) else { return nil }
            self = .registered(value)
        }
    }

    var rawValue: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .opencode: return "opencode"
        case .rovodev: return "rovodev"
        case .registered(let id): return id
        }
    }

    init(from decoder: Decoder) throws {
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
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
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
    case claude(model: String?, permissionMode: String?)
    case codex(model: String?, approvalPolicy: String?, sandboxMode: String?, effort: String?)
    case opencode(providerModel: String?, agentName: String?)
    case rovodev
    case registered(CmuxVaultAgentRegistration)
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

    /// Shell command that resumes this session in a new terminal, with the agent's
    /// known per-session settings injected as CLI flags.
    var resumeCommand: String {
        switch specifics {
        case let .claude(model, permissionMode):
            var parts = ["claude --resume \(sessionId)"]
            if let model, !model.isEmpty {
                parts.append("--model \(Self.shellQuote(model))")
            }
            if let permissionMode, !permissionMode.isEmpty {
                parts.append("--permission-mode \(Self.shellQuote(permissionMode))")
            }
            let environment = claudeConfigDirectoryForResume.map {
                ["CLAUDE_CONFIG_DIR": $0, "CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV": "1", "CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS": "CLAUDE_CONFIG_DIR"]
            } ?? [:]
            return Self.withShellEnvironment(environment, command: parts.joined(separator: " "))
        case let .codex(model, approval, sandbox, effort):
            var parts = ["codex resume \(sessionId)"]
            if let model, !model.isEmpty {
                parts.append("-m \(Self.shellQuote(model))")
            }
            if let approval, !approval.isEmpty {
                parts.append("-a \(Self.shellQuote(approval))")
            }
            if let sandbox, !sandbox.isEmpty {
                parts.append("-s \(Self.shellQuote(sandbox))")
            }
            if let effort, !effort.isEmpty {
                parts.append("-c model_reasoning_effort=\(Self.shellQuote(effort))")
            }
            return parts.joined(separator: " ")
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
        case .registered(let registration):
            guard let kind = RestorableAgentKind(rawValue: registration.id),
                  let command = AgentResumeCommandBuilder.resumeShellCommand(
                      kind: kind,
                      sessionId: sessionId,
                      launchCommand: AgentLaunchCommandSnapshot(
                          launcher: registration.id,
                          executablePath: nil,
                          arguments: [registration.defaultExecutable],
                          workingDirectory: cwd,
                          environment: nil,
                          capturedAt: nil,
                          source: "vault"
                      ),
                      workingDirectory: nil,
                      registrationOverride: registration
                  ) else {
                return "\(Self.shellQuote(registration.defaultExecutable)) --session \(Self.shellQuote(sessionId))"
            }
            return command
        }
    }

    var resumeCommandWithCwd: String {
        guard let cwd, !cwd.isEmpty else {
            return resumeCommand
        }
        return "cd \(Self.shellQuote(cwd)) && \(resumeCommand)"
    }

    private var claudeConfigDirectoryForResume: String? {
        guard agent == .claude,
              let fileURL else {
            return nil
        }
        let pathComponents = fileURL.standardizedFileURL.pathComponents
        guard let projectsIndex = pathComponents.lastIndex(of: "projects"),
              projectsIndex > 0 else {
            return nil
        }
        let configComponents = Array(pathComponents[..<projectsIndex])
        let configDir = NSString.path(withComponents: configComponents)
        return configDir.isEmpty ? nil : ClaudeConfigDirectoryPath.preferredPath(configDir)
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

    /// Single-quote a value for safe shell injection. Escapes embedded single quotes.
    private static func shellQuote(_ value: String) -> String {
        if value.range(of: "[^A-Za-z0-9_./:=+-]", options: .regularExpression) == nil {
            return value
        }
        let escaped = value.replacingOccurrences(of: "'", with: #"'\''"#)
        return "'\(escaped)'"
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
