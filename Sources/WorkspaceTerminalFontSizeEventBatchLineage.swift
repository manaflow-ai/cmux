import CmuxTerminal
import CmuxTerminalCore
import Foundation

extension WorkspaceTerminalFontSizeCoordinator {
    /// Shared result for the Dock and workspace phases of one coalesced event
    /// batch. The Dock phase always precedes the workspace phases in the sealed
    /// ledger, so workspace fallbacks can derive from the bounded source probe.
    final class EventBatchLineage {
        let configuration:
            WorkspaceTerminalFontConfigurationSnapshot
        var windowDockSourceLineage: TerminalFontSizeLineage?
        var windowDockSourceLineageSelection =
            TerminalFontSizeLineageSelection()
        var windowDockLineageSelection =
            TerminalFontSizeLineageSelection()
        var didParticipateWindowDock = false
        var remainingRequestTokens: Set<UUID> = []
        let deferredProjectionToken: UUID?
        let windowDockTransferToken = UUID()
        let workspaceTransferToken = UUID()

        init(
            configuration:
                WorkspaceTerminalFontConfigurationSnapshot,
            deferredProjectionToken: UUID? = nil
        ) {
            self.configuration = configuration
            self.deferredProjectionToken =
                deferredProjectionToken
        }
    }
}
