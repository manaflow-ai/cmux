import Foundation
import SwiftUI
import CmuxSidebarUI

struct SidebarBonsplitWorkspaceRowDropModifier: ViewModifier {
    let isEnabled: Bool
    let targetWorkspaceId: UUID
    let bonsplitSourceWorkspaceId: @MainActor (UUID) -> UUID?
    let moveBonsplitTabToWorkspace: @MainActor (BonsplitTabDragPayload.Transfer, UUID) -> Bool
    let syncSidebarSelectionAfterDrop: @MainActor () -> Void
    @Binding var selectedTabIds: Set<UUID>

    func body(content: Content) -> some View {
        let delegate = SidebarBonsplitTabDropDelegate(
            isEnabled: isEnabled,
            targetWorkspaceId: targetWorkspaceId,
            bonsplitSourceWorkspaceId: bonsplitSourceWorkspaceId,
            moveBonsplitTabToWorkspace: moveBonsplitTabToWorkspace,
            syncSidebarSelectionAfterDrop: syncSidebarSelectionAfterDrop,
            selectedTabIds: $selectedTabIds
        )
        return content.onDrop(of: BonsplitTabDragPayload.dropContentTypes, delegate: delegate)
    }
}
