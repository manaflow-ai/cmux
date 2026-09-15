import SwiftUI

/// Applies completed empty-area actions to the sidebar's selection bindings and model.
@MainActor
struct SidebarWorkspaceTableEmptyAreaActions {
    let tabManager: TabManager
    let selectedWorkspaceIds: Binding<Set<UUID>>
    let selectionAnchorIndex: Binding<Int?>
    let selectTabs: () -> Void

    func clearSelection() {
        selectedWorkspaceIds.wrappedValue = []
        selectionAnchorIndex.wrappedValue = nil
        // The next key event can arrive before SwiftUI's onChange.
        tabManager.setSidebarSelectedWorkspaceIds([])
    }

    func createWorkspaceAtEnd() {
        if tabManager.selectedTab?.isRemoteTmuxMirror == true {
            _ = AppDelegate.shared?.performNewWorkspaceAction(
                tabManager: tabManager,
                debugSource: "sidebar.emptyArea.remoteTmux"
            )
        } else {
            tabManager.addWorkspaceIfActive(placementOverride: .end)
        }
        if let selectedId = tabManager.selectedTabId {
            selectedWorkspaceIds.wrappedValue = [selectedId]
            selectionAnchorIndex.wrappedValue = tabManager.tabs.firstIndex { $0.id == selectedId }
        }
        selectTabs()
    }
}
