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
        return normalizedHookValue(launchCommand?.source)?.lowercased() != "process"
    }
}
