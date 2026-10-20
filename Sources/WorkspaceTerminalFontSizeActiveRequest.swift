import CmuxTerminal
import Foundation

extension WorkspaceTerminalFontSizeCoordinator {
    struct ActiveRequest {
        let request: PendingRequest
        let inheritanceContext: TerminalFontSizeChangeInheritanceContext
        var discovery: WorkspaceTerminalFontSizePanelDiscovery
        var pendingCandidate:
            WorkspaceTerminalFontSizePanelDiscovery.Candidate?
        var seenPanelIds: Set<UUID> = []
        var participatingLineage = TerminalFontSizeLineageSelection()
        let configuredRuntimePoints: Float32
        let magnificationPercent: Int

        var token: UUID {
            request.token
        }
    }
}
