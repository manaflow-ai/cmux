import Foundation

extension CMUXCLI {
    func agentHookSessionHasDurableResumeEvidence(
        kind: String,
        launchCommand: AgentHookLaunchCommandRecord?
    ) -> Bool {
        guard normalizedHookValue(launchCommand?.source)?.lowercased() != "rejected" else { return false }
        guard kind == "codex" else { return true }
        guard let launchCommand else { return true }
        if normalizedHookValue(launchCommand.environment?["CODEX_HOME"]) != nil {
            return true
        }
        guard !launchCommand.arguments.isEmpty else { return false }
        switch normalizedHookValue(launchCommand.source)?.lowercased() {
        case nil, "environment", "process":
            return true
        default:
            return false
        }
    }

    func preferredAgentHookResumeLaunchCommand(
        kind: String,
        current: AgentHookLaunchCommandRecord?,
        mapped: ClaudeHookSessionRecord?
    ) -> AgentHookLaunchCommandRecord? {
        if normalizedHookValue(current?.source)?.lowercased() == "rejected" {
            return current
        }
        if let current, agentHookSessionHasDurableResumeEvidence(kind: kind, launchCommand: current) {
            return current
        }
        if let launchCommand = mapped?.launchCommand,
           agentHookSessionHasDurableResumeEvidence(kind: kind, launchCommand: launchCommand) {
            return launchCommand
        }
        if agentHookMappedSessionHasDurableTargetEvidence(kind: kind, mapped: mapped) {
            return nil
        }
        return current ?? mapped?.launchCommand
    }

    func preferredAgentHookResumeWorkingDirectory(
        kind: String,
        current: AgentHookLaunchCommandRecord?,
        currentCwd: String?,
        mapped: ClaudeHookSessionRecord?
    ) -> String? {
        if normalizedHookValue(current?.source)?.lowercased() == "rejected" {
            return currentCwd ?? mapped?.cwd
        }
        if let current, agentHookSessionHasDurableResumeEvidence(kind: kind, launchCommand: current) {
            return currentCwd ?? mapped?.cwd
        }
        if agentHookMappedSessionHasDurableTargetEvidence(kind: kind, mapped: mapped) {
            return mapped?.cwd ?? currentCwd
        }
        return currentCwd ?? mapped?.cwd
    }

    func agentHookMappedSessionHasDurableTargetEvidence(
        kind: String,
        mapped: ClaudeHookSessionRecord?
    ) -> Bool {
        guard let mapped else { return false }
        guard normalizedHookValue(mapped.launchCommand?.source)?.lowercased() != "rejected" else { return false }
        guard kind == "codex" else { return true }
        if mapped.isRestorable == true { return true }
        if normalizedHookValue(mapped.transcriptPath) != nil { return true }
        guard let launchCommand = mapped.launchCommand else { return false }
        if normalizedHookValue(launchCommand.environment?["CODEX_HOME"]) != nil { return true }
        guard !launchCommand.arguments.isEmpty else { return false }
        switch normalizedHookValue(launchCommand.source)?.lowercased() {
        case nil, "environment", "process":
            return true
        default:
            return false
        }
    }
}
