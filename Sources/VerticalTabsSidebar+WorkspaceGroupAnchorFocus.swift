import AppKit
import CmuxFoundation
import CmuxWorkspaces
import SwiftUI

extension VerticalTabsSidebar {
    /// Applies one shared group-header selection action to the live anchor.
    @MainActor
    static func focusWorkspaceGroupAnchor(
        groupId: UUID,
        modifiers: NSEvent.ModifierFlags,
        tabManager: TabManager,
        selectedTabIds: Binding<Set<UUID>>,
        lastSidebarSelectionIndex: Binding<Int?>
    ) {
        let anchorId: UUID
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            guard let anchor = tabManager.workspaceGroupAnchor(for: groupId) else { return }
            let selection = SidebarSelectionKindPolicy().anchorCmdClickSelection(
                current: selectedTabIds.wrappedValue,
                clickedAnchorId: anchor.id,
                anchorIds: Set(tabManager.workspaceGroups.compactMap(\.liveAnchorWorkspaceId))
            )
            selectedTabIds.wrappedValue = selection
            guard let selectedAnchor = tabManager.selectWorkspaceGroupAnchor(for: groupId) else { return }
            anchorId = selectedAnchor.id
        } else {
            guard let selectedAnchor = tabManager.selectWorkspaceGroupAnchor(for: groupId) else { return }
            anchorId = selectedAnchor.id
            if selectedTabIds.wrappedValue != [anchorId] {
                selectedTabIds.wrappedValue = [anchorId]
            }
        }
        lastSidebarSelectionIndex.wrappedValue = tabManager.tabs.firstIndex { $0.id == anchorId }
    }
}
