import Foundation

extension CmuxTopProcessSnapshot {
    /// Verifies that a prompt-boundary candidate belongs to the configured foreground agent.
    func matchingPromptAgentDefinition(
        workspaceID: UUID,
        surfaceID: UUID,
        agentID: String
    ) -> CmuxTaskManagerCodingAgentDefinition? {
        for process in cmuxScopedProcesses() where
            process.cmuxWorkspaceID == workspaceID
                && process.cmuxSurfaceID == surfaceID
                && process.isTerminalForegroundProcessGroup {
            let details = Self.processArgumentsAndEnvironment(for: process.pid)
            guard let definition = CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: process.name,
                processPath: process.path,
                arguments: details?.arguments ?? [],
                environment: details?.environment ?? [:]
            ),
            definition.id == agentID,
            definition.promptTurnDetection != nil else {
                continue
            }
            return definition
        }
        return nil
    }
}
