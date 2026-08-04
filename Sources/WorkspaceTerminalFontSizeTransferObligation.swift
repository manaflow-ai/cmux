import CmuxTerminal
import Foundation

extension WorkspaceTerminalFontSizeCoordinator {
    final class TransferObligation {
        weak var panel: TerminalPanel?
        let panelId: UUID
        weak var resourceState: TransferResourceState?
        var nextRequest: TransferRequestRecord?
        var throughRequest: TransferRequestRecord
        var panelTransfer:
            WorkspaceTerminalFontSizePanelTransfer?
        var panelTransferStageToken: UUID?
        var heapIndex: Int?
        var heapOrder: UInt64 = 0

        init(
            panel: TerminalPanel,
            resourceState: TransferResourceState,
            nextRequest: TransferRequestRecord,
            throughRequest: TransferRequestRecord
        ) {
            self.panel = panel
            panelId = panel.id
            self.resourceState = resourceState
            self.nextRequest = nextRequest
            self.throughRequest = throughRequest
        }
    }
}
