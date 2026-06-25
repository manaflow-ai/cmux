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
        if normalizedHookValue(launchCommand.source)?.lowercased() == "default" { return true }
        guard !launchCommand.arguments.isEmpty else { return false }
        let source = normalizedHookValue(launchCommand.source)?.lowercased()
        if source == "environment", codexLaunchEnvironmentIsWeak(launchCommand.environment) {
            return false
        }
        switch source {
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
        let currentSource = normalizedHookValue(current?.source)?.lowercased()
        if let current, currentSource != "default", agentHookSessionHasDurableResumeEvidence(kind: kind, launchCommand: current) {
            return current
        }
        if let launchCommand = mapped?.launchCommand,
           agentHookSessionHasDurableResumeEvidence(kind: kind, launchCommand: launchCommand) {
            return launchCommand
        }
        if let current, currentSource == "default", agentHookSessionHasDurableResumeEvidence(kind: kind, launchCommand: current) {
            return current
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
        let currentSource = normalizedHookValue(current?.source)?.lowercased()
        if let current, currentSource != "default", agentHookSessionHasDurableResumeEvidence(kind: kind, launchCommand: current) {
            return currentCwd ?? mapped?.cwd
        }
        if let launchCommand = mapped?.launchCommand,
           agentHookSessionHasDurableResumeEvidence(kind: kind, launchCommand: launchCommand) {
            return mapped?.cwd ?? currentCwd
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
        if let transcriptPath = normalizedHookValue(mapped.transcriptPath),
           FileManager.default.fileExists(atPath: (transcriptPath as NSString).expandingTildeInPath) {
            return true
        }
        guard let launchCommand = mapped.launchCommand else { return false }
        if normalizedHookValue(launchCommand.environment?["CODEX_HOME"]) != nil { return true }
        if normalizedHookValue(launchCommand.source)?.lowercased() == "default" { return true }
        guard !launchCommand.arguments.isEmpty else { return false }
        let source = normalizedHookValue(launchCommand.source)?.lowercased()
        if source == "environment", codexLaunchEnvironmentIsWeak(launchCommand.environment) {
            return false
        }
        switch source {
        case nil, "environment", "process":
            return true
        default:
            return false
        }
    }

    private func codexLaunchEnvironmentIsWeak(_ environment: [String: String]?) -> Bool {
        normalizedHookValue(environment?["CODEX_HOME"]) == nil
            && (normalizedHookValue(environment?["ANTHROPIC_BASE_URL"]) != nil
                || normalizedHookValue(environment?["CLAUDE_CONFIG_DIR"]) != nil)
    }
}
