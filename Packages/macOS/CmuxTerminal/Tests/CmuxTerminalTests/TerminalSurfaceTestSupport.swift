@testable import CmuxTerminal

@MainActor
extension TerminalSurface {
    func markAgentCommandShimPreparationReady() {
        agentCommandShimPreparation = TerminalSurfaceAgentCommandShimPreparation(
            commandShims: nil,
            launchResourceSnapshot: .unavailable
        )
    }
}
