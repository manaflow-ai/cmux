import Foundation

extension WorkspaceTerminalFontSizeArbiter {
    final class PanelTransferStage {
        let token = UUID()
        weak var coordinator:
            WorkspaceTerminalFontSizeCoordinator?
        weak var previous: PanelTransferStage?
        var next: PanelTransferStage?

        init(
            coordinator:
                WorkspaceTerminalFontSizeCoordinator
        ) {
            self.coordinator = coordinator
        }
    }
}
