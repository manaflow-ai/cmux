import Foundation

extension CMUXCLI {
    func agentHookSessionHasDurableResumeEvidence(
        kind: String,
        launchCommand: AgentHookLaunchCommandRecord?
    ) -> Bool {
        guard kind == "codex" else { return true }
        guard let launchCommand else { return true }
        guard normalizedHookValue(launchCommand.source)?.lowercased() != "rejected" else { return false }
        if normalizedHookValue(launchCommand.environment?["CODEX_HOME"]) != nil {
            return true
        }
        guard !launchCommand.arguments.isEmpty else { return false }
        switch normalizedHookValue(launchCommand.source)?.lowercased() {
        case "environment", "process":
            return true
        default:
            return false
        }
    }

    func preferredAgentHookResumeLaunchCommand(
        kind: String,
        current: AgentHookLaunchCommandRecord?,
        mapped: AgentHookLaunchCommandRecord?
    ) -> AgentHookLaunchCommandRecord? {
        if let current, agentHookSessionHasDurableResumeEvidence(kind: kind, launchCommand: current) {
            return current
        }
        if let mapped, agentHookSessionHasDurableResumeEvidence(kind: kind, launchCommand: mapped) {
            return mapped
        }
        return current ?? mapped
    }

    func agentHookMappedSessionHasDurableTargetEvidence(
        kind: String,
        mapped: ClaudeHookSessionRecord?
    ) -> Bool {
        guard kind == "codex" else { return mapped != nil }
        guard let mapped else { return false }
        if normalizedHookValue(mapped.transcriptPath) != nil { return true }
        guard let launchCommand = mapped.launchCommand else { return false }
        guard normalizedHookValue(launchCommand.source)?.lowercased() != "rejected" else { return false }
        if normalizedHookValue(launchCommand.environment?["CODEX_HOME"]) != nil { return true }
        guard !launchCommand.arguments.isEmpty else { return false }
        switch normalizedHookValue(launchCommand.source)?.lowercased() {
        case "environment", "process":
            return true
        default:
            return false
        }
    }
}
