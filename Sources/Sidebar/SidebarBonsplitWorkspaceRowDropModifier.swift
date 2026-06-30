import Foundation
import SwiftUI

struct SidebarBonsplitWorkspaceRowDropModifier: ViewModifier {
    let isEnabled: Bool
    let targetWorkspaceId: UUID
    let tabManager: TabManager
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?

    @ViewBuilder
    func body(content: Content) -> some View {
        if !isEnabled {
            content
        } else {
            let delegate = SidebarBonsplitTabDropDelegate(
                targetWorkspaceId: targetWorkspaceId,
                tabManager: tabManager,
                selectedTabIds: $selectedTabIds,
                lastSidebarSelectionIndex: $lastSidebarSelectionIndex
            )
            content.onDrop(of: BonsplitTabDragPayload.dropContentTypes, delegate: delegate)
        }
    }
}
