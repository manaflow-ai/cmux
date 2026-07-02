import Foundation
import SwiftUI

@MainActor
struct SidebarBonsplitTabDropDelegate: DropDelegate {
    let isEnabled: Bool
    let targetWorkspaceId: UUID
    let bonsplitSourceWorkspaceId: @MainActor (UUID) -> UUID?
    let moveBonsplitTabToWorkspace: @MainActor (BonsplitTabDragPayload.Transfer, UUID) -> Bool
    let syncSidebarSelectionAfterDrop: @MainActor () -> Void
    @Binding var selectedTabIds: Set<UUID>

    func validateDrop(info: DropInfo) -> Bool {
        guard isEnabled else { return false }
        guard info.hasItemsConforming(to: [BonsplitTabDragPayload.typeIdentifier]) else { return false }
        return BonsplitTabDragPayload.currentTransfer() != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return nil }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info),
              let transfer = BonsplitTabDragPayload.currentTransfer() else {
            return false
        }

        if bonsplitSourceWorkspaceId(transfer.tab.id) == targetWorkspaceId {
            syncSidebarSelectionAfterDrop()
            return true
        }

        guard moveBonsplitTabToWorkspace(transfer, targetWorkspaceId) else {
            return false
        }

        selectedTabIds = [targetWorkspaceId]
        syncSidebarSelectionAfterDrop()
        return true
    }
}
