import Foundation

extension CMUXCLI {
    func agentHookSessionHasDurableResumeEvidence(
        kind: String,
        launchCommand: AgentHookLaunchCommandRecord?
    ) -> Bool {
        guard kind == "codex" else { return true }
        return launchCommand?.arguments.isEmpty == false
            || normalizedHookValue(launchCommand?.environment?["CODEX_HOME"]) != nil
    }
}
