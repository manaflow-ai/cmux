public import Foundation
import CMUXAgentLaunch
import CmuxFoundation

/// A discovered agent session row: identity, agent kind, title, working directory,
/// git/PR context, modification time, and the agent-specific data needed to build a
/// resume command.
///
/// The localized `displayTitle` and the resume-command rendering remain app-side
/// extensions: the former binds `String(localized:)` against the app bundle, and the
/// latter routes the Hermes case through an app-side resume builder.
public struct SessionEntry: Identifiable, Hashable {
    public let id: String
    public let agent: SessionAgent
    /// Native session identifier for the agent's CLI (used to build the resume command).
    public let sessionId: String
    public let title: String
    public let cwd: String?
    public let gitBranch: String?
    public let pullRequest: PullRequestLink?
    public let modified: Date
    public let fileURL: URL?
    public let specifics: AgentSpecifics

    public init(
        id: String,
        agent: SessionAgent,
        sessionId: String,
        title: String,
        cwd: String?,
        gitBranch: String?,
        pullRequest: PullRequestLink?,
        modified: Date,
        fileURL: URL?,
        specifics: AgentSpecifics
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
        self.specifics = specifics
    }

    public var resumeWorkingDirectory: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        if case .registered(let registration) = specifics,
           registration.cwd == .ignore {
            return nil
        }
        return cwd
    }

    public func withClaudeConfigDirectoryForResume(_ configDirectory: String?) -> SessionEntry {
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

    public static func withShellEnvironment(
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

    public static func singleQuotedShellCommand(
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
        value.posixShellQuoted
    }

    /// Single-quote a value for safe shell injection. Escapes embedded single quotes.
    public static func shellQuote(_ value: String) -> String {
        value.shellQuoted
    }

    /// Sandbox-policy values the Codex CLI `--sandbox` flag accepts.
    ///
    /// cmux captures Codex's *internal* sandbox-policy `type`, which is a
    /// superset of the CLI vocabulary (it also includes `disabled`, `managed`,
    /// and may grow further). Those extra types have no `--sandbox` equivalent
    /// and must never be forwarded as `-s`, or Codex rejects the resumed command
    /// (see https://github.com/manaflow-ai/cmux/issues/5262).
    public static let codexCLISandboxModes: Set<String> = [
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
    public static func codexApprovalSandboxArguments(
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

    public static func claudeDisplayTitle(from raw: String, isMeta: Bool = false) -> String? {
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

    public static func isClaudeSyntheticEnvelope(_ raw: String) -> Bool {
        isClaudeLocalCommandEnvelope(raw)
            || raw.hasPrefix("<system-reminder>")
    }

    public static func isClaudeLocalCommandEnvelope(_ raw: String) -> Bool {
        raw.hasPrefix("<local-command-")
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    public var cwdLabel: String? {
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

    public var cwdBasename: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return (cwd as NSString).lastPathComponent
    }
}
