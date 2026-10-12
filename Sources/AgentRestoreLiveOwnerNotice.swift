import CMUXAgentLaunch
import Foundation

/// Renders the terminal-visible explanation for a suppressed duplicate restore.
struct AgentRestoreLiveOwnerNotice: Sendable {
    let processID: Int

    func startupInput(dialect: TerminalStartupShellDialect) -> String {
        let format = String(
            localized: "agentRestore.liveOwner.notice",
            defaultValue: "This agent session is already running in process %1$lld. cmux did not start another copy. To take it over here, stop process %1$lld, then run 'cmux restore --surface' again."
        )
        let message = String(
            format: format,
            // A PID is a shell-facing identifier, not localized prose. Keep
            // grouping separators out so the value remains one unambiguous
            // numeric token in every locale.
            locale: Locale(identifier: "en_US_POSIX"),
            Int64(processID)
        )
        return startupInput(message: message, dialect: dialect)
    }

    /// Renders an already-localized message for shell-boundary tests.
    func startupInput(
        message: String,
        dialect: TerminalStartupShellDialect
    ) -> String {
        AgentRestoreNoticeInput(message: message).startupInput(dialect: dialect)
    }
}

/// Builds an attach-only startup input for a session whose writer already lives.
/// This never emits a resume verb, so restoring a live owner cannot create a
/// second agent writer.
enum AgentRestoreAttachCommand {
    /// Plans one attach-only startup for either deferred restore owner. Keeping
    /// owner admission on this path prevents Workspace and Dock from drifting
    /// on Claude versus tmux selection.
    static func startupInput(
        liveOwner: LiveAgentSessionOwner,
        restorableAgent: SessionRestorableAgentSnapshot?,
        resumeBinding: SurfaceResumeBindingSnapshot?,
        tmuxStartCommand: String?,
        workingDirectory: String?,
        dialect: TerminalStartupShellDialect = .loginShell
    ) -> String? {
        startupInput(
            kind: liveOwner.kind,
            sessionID: liveOwner.sessionID,
            launchCommand: restorableAgent?.launchCommand ?? resumeBinding?.launchCommand,
            tmuxStartCommand: tmuxStartCommand,
            workingDirectory: workingDirectory,
            dialect: dialect
        )
    }

    static func startupInput(
        kind: String,
        sessionID: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        tmuxStartCommand: String?,
        workingDirectory: String?,
        dialect: TerminalStartupShellDialect = .loginShell
    ) -> String? {
        if let tmuxCommand = tmuxAttachCommand(tmuxStartCommand) {
            return typedInput(
                command: TerminalStartupWorkingDirectoryPrefix.prefix(
                    tmuxCommand,
                    workingDirectory: workingDirectory
                ),
                dialect: dialect
            )
        }
        guard kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "claude",
              let command = claudeAttachCommand(sessionID: sessionID, launchCommand: launchCommand) else {
            return nil
        }
        return typedInput(
            command: TerminalStartupWorkingDirectoryPrefix.prefix(
                command,
                workingDirectory: workingDirectory
            ),
            dialect: dialect
        )
    }

    private static func tmuxAttachCommand(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let words = TerminalStartupWorkingDirectoryPrefix.shellWordRanges(raw).map(\.value)
        if words.count == 11 {
            let isCanonicalPrefix = words[0] == "/usr/bin/env"
                && words[1] == "TMUX="
                && words[2] == "CMUX_LOCAL_TMUX=1"
            let isLegacyPrefix = words[0] == "TMUX="
                && words[1] == "CMUX_LOCAL_TMUX=1"
                && words[2] == "exec"
            let conditionPrefix = "#{==:#{@cmux_local_server_id},"
            let hasValidatedIdentity = words[8].hasPrefix(conditionPrefix)
                && words[8].hasSuffix("}")
                && UUID(
                    uuidString: String(
                        words[8].dropFirst(conditionPrefix.count).dropLast()
                    )
                ) != nil
            let actionWords = TerminalStartupWorkingDirectoryPrefix.shellWordRanges(words[9])
                .map(\.value)
            let hasValidatedTarget = actionWords.count == 3
                && actionWords[0] == "attach-session"
                && actionWords[1] == "-t"
                && actionWords[2].range(of: "^\\$[0-9]+$", options: .regularExpression) != nil
            if (isCanonicalPrefix || isLegacyPrefix),
               URL(fileURLWithPath: words[3]).lastPathComponent == "tmux",
               words[4] == "-S",
               (words[5] as NSString).lastPathComponent == "server.sock",
               words[6] == "if-shell",
               words[7] == "-F",
               hasValidatedIdentity,
               hasValidatedTarget,
               words[10] == "run-shell false" {
                return raw
            }
        }
        guard words.count >= 4,
              URL(fileURLWithPath: words[0]).lastPathComponent == "tmux",
              words[1] == "attach" || words[1] == "attach-session",
              words[2] == "-t" else { return nil }
        return raw
    }

    private static func claudeAttachCommand(
        sessionID: String,
        launchCommand: AgentLaunchCommandSnapshot?
    ) -> String? {
        let session = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty else { return nil }
        return ClaudeBackgroundSessionAttach.attachArguments(
            target: session,
            launchArguments: launchCommand?.arguments ?? [],
            launcher: launchCommand?.launcher
        )
        .map(TerminalStartupShellQuoting.singleQuoted)
        .joined(separator: " ")
    }

    /// Reattaches a Claude Code background session the daemon still hosts.
    ///
    /// The attach runs through `/usr/bin/env` so the captured config directory
    /// and routing keys reach the same daemon in every shell dialect.
    static func claudeBackgroundStartupInput(
        _ plan: ClaudeBackgroundAttachPlan,
        dialect: TerminalStartupShellDialect = .loginShell
    ) -> String {
        let assignments = plan.environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        let words = (assignments.isEmpty ? [] : ["/usr/bin/env"] + assignments) + plan.arguments
        // The leading space keeps the typed command (config dir, routing URL)
        // out of shell history under HISTCONTROL=ignorespace / HIST_IGNORE_SPACE.
        return " " + typedInput(
            command: words.map(TerminalStartupShellQuoting.singleQuoted).joined(separator: " "),
            dialect: dialect
        )
    }

    private static func typedInput(
        command: String,
        dialect: TerminalStartupShellDialect
    ) -> String {
        TerminalStartupTypedShellCommand(dialect: dialect).typedInput(posixCommand: command) + "\n"
    }
}
