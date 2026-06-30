import Foundation
import SwiftUI

struct SidebarBonsplitWorkspaceRowDropModifier: ViewModifier {
    let isEnabled: Bool
    let targetWorkspaceId: UUID
    let tabManager: TabManager
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?

    func body(content: Content) -> some View {
        let delegate = SidebarBonsplitTabDropDelegate(
            isEnabled: isEnabled,
            targetWorkspaceId: targetWorkspaceId,
            tabManager: tabManager,
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex
        )
        return content.onDrop(of: BonsplitTabDragPayload.dropContentTypes, delegate: delegate)
    }
}
