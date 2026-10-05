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
        guard words.first.map({ URL(fileURLWithPath: $0).lastPathComponent == "tmux" }) == true,
              words.contains(where: { $0 == "attach" || $0 == "attach-session" }) else {
            return nil
        }
        return raw
    }

    private static func claudeAttachCommand(
        sessionID: String,
        launchCommand: AgentLaunchCommandSnapshot?
    ) -> String? {
        let session = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty else { return nil }
        let arguments = launchCommand?.arguments ?? []
        let executableIndex = arguments.firstIndex {
            URL(fileURLWithPath: $0).lastPathComponent == "claude"
        }
        let prefix: [String]
        if let executableIndex {
            let outer = Array(arguments[..<executableIndex])
            prefix = outer + [arguments[executableIndex]]
        } else if launchCommand?.launcher?.lowercased() == "sr" {
            prefix = ["sr", "claude"]
        } else {
            prefix = ["claude"]
        }
        return (prefix + ["attach", session])
            .map(TerminalStartupShellQuoting.singleQuoted)
            .joined(separator: " ")
    }

    private static func typedInput(
        command: String,
        dialect: TerminalStartupShellDialect
    ) -> String {
        TerminalStartupTypedShellCommand(dialect: dialect).typedInput(posixCommand: command) + "\n"
    }
}
