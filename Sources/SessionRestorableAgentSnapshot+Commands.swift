import Foundation

extension SessionRestorableAgentSnapshot {
    var resumeCommand: String? {
        if kind.restoreMode == .relaunchCommand {
            return AgentRelaunchCommandBuilder().shellCommand(
                kind: kind,
                launchCommand: launchCommand,
                workingDirectory: workingDirectory
            )
        }
        return AgentResumeCommandBuilder.resumeShellCommand(
            kind: kind,
            sessionId: sessionId,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory,
            registrationOverride: registration
        )
    }

    var forkCommand: String? {
        guard kind.restoreMode == .resumeSession else { return nil }
        return AgentResumeCommandBuilder.forkShellCommand(
            kind: kind,
            sessionId: sessionId,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory,
            registrationOverride: registration
        )
    }

    var agentDisplayName: String {
        if let name = registration?.name.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return kind.displayName
    }
}
