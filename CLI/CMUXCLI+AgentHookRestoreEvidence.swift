import Foundation

extension CMUXCLI {
    func agentHookSessionHasDurableResumeEvidence(
        kind: String,
        launchCommand: AgentHookLaunchCommandRecord?
    ) -> Bool {
        guard kind == "codex" else { return true }
        if normalizedHookValue(launchCommand?.environment?["CODEX_HOME"]) != nil {
            return true
        }
        guard launchCommand?.arguments.isEmpty == false else { return false }
        return normalizedHookValue(launchCommand?.source)?.lowercased() == "environment"
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
}
