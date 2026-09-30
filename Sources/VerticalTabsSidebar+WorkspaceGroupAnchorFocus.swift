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
        guard let group = tabManager.workspaceGroups.first(where: { $0.id == groupId }),
              let anchor = tabManager.workspaceGroupAnchor(for: groupId),
              let target = tabManager.workspaceGroupHeaderTarget(for: groupId) else { return }
        let hasRealMember = tabManager.tabs.contains { $0.groupId == groupId && $0.id != anchor.id }
        if group.anchorWorkspaceProvenance == .generated,
           !hasRealMember,
           tabManager.workspaceGroupGeneratedAnchorIsUntouched(anchor) {
            tabManager.toggleWorkspaceGroupCollapsed(groupId: groupId)
            return
        }

        let anchorId: UUID
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            let selection = SidebarSelectionKindPolicy().anchorCmdClickSelection(
                current: selectedTabIds.wrappedValue,
                clickedAnchorId: anchor.id,
                anchorIds: Set(tabManager.workspaceGroups.compactMap(\.liveAnchorWorkspaceId))
            )
            selectedTabIds.wrappedValue = selection
            tabManager.selectWorkspace(target)
            anchorId = anchor.id
        } else {
            tabManager.selectWorkspace(target)
            anchorId = target.id
            if selectedTabIds.wrappedValue != [anchorId] {
                selectedTabIds.wrappedValue = [anchorId]
            }
        }
        lastSidebarSelectionIndex.wrappedValue = tabManager.tabs.firstIndex { $0.id == anchorId }
    }
}
