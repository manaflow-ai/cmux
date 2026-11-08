import Foundation

extension WorkspaceTerminalFontSizeArbiter {
    final class PanelTransferState {
        let handle: WorkspaceTerminalFontSizePanelTransfer
        var destination: PanelTransferDestinationKey?
        var stageHead: PanelTransferStage?
        var stageTail: PanelTransferStage?
        var stagesByToken: [UUID: PanelTransferStage] = [:]

        init(
            handle:
                WorkspaceTerminalFontSizePanelTransfer
        ) {
            self.handle = handle
        }

        func append(
            _ stage: PanelTransferStage
        ) {
            stage.previous = stageTail
            stageTail?.next = stage
            if stageHead == nil {
                stageHead = stage
            }
            stageTail = stage
            stagesByToken[stage.token] = stage
        }

        @discardableResult
        func remove(
            token: UUID
        ) -> Bool {
            guard let stage =
                    stagesByToken.removeValue(
                        forKey: token
                    ) else {
                return false
            }
            let previous = stage.previous
            let next = stage.next
            previous?.next = next
            next?.previous = previous
            if stageHead === stage {
                stageHead = next
            }
            if stageTail === stage {
                stageTail = previous
            }
            stage.previous = nil
            stage.next = nil
            return true
        }
    }
}
