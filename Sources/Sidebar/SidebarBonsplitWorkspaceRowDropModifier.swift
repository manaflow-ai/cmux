import Foundation
import SwiftUI

struct SidebarBonsplitWorkspaceRowDropModifier: ViewModifier {
    let isEnabled: Bool
    let targetWorkspaceId: UUID
    let bonsplitSourceWorkspaceId: @MainActor (UUID) -> UUID?
    let moveBonsplitTabToWorkspace: @MainActor (BonsplitTabDragPayload.Transfer, UUID) -> Bool
    let syncSidebarSelectionAfterDrop: @MainActor () -> Void
    @Binding var selectedTabIds: Set<UUID>

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            let delegate = SidebarBonsplitTabDropDelegate(
                isEnabled: isEnabled,
                targetWorkspaceId: targetWorkspaceId,
                bonsplitSourceWorkspaceId: bonsplitSourceWorkspaceId,
                moveBonsplitTabToWorkspace: moveBonsplitTabToWorkspace,
                syncSidebarSelectionAfterDrop: syncSidebarSelectionAfterDrop,
                selectedTabIds: $selectedTabIds
            )
            content.onDrop(of: BonsplitTabDragPayload.dropContentTypes, delegate: delegate)
        } else {
            content
        }
    }
}
