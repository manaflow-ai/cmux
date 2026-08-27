import Foundation

/// Stable currency carried by a terminal while accepted font mutations cross
/// container and window coordinators.
@MainActor
final class WorkspaceTerminalFontSizePanelTransfer {
    let id = UUID()
    let panelId: UUID
    weak var arbiter:
        WorkspaceTerminalFontSizeArbiter?

    init(
        panelId: UUID,
        arbiter: WorkspaceTerminalFontSizeArbiter
    ) {
        self.panelId = panelId
        self.arbiter = arbiter
    }

    func attach(to workspace: Workspace) {
        guard let arbiter else { return }
        workspace.setTerminalFontSizeChangeArbiter(arbiter)
        arbiter.associatePanelTransfer(
            self,
            with: workspace
        )
    }

    func attach(to windowDock: DockSplitStore) {
        guard let arbiter else { return }
        windowDock.terminalFontSizeChangeArbiter = arbiter
        arbiter.associatePanelTransfer(
            self,
            with: windowDock
        )
    }

    var isActive: Bool {
        arbiter?.isPanelTransferActive(self) == true
    }
}
