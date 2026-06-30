import Foundation
import SwiftUI

@MainActor
func openWorkspaceTasksFromSidebarRow(
    tab: Tab,
    tabManager: TabManager,
    selectedTabIds: Binding<Set<UUID>>,
    lastSidebarSelectionIndex: Binding<Int?>,
    isPopoverPresented: Binding<Bool>
) {
    isPopoverPresented.wrappedValue = false
    selectedTabIds.wrappedValue = [tab.id]
    lastSidebarSelectionIndex.wrappedValue = tabManager.tabs.firstIndex { $0.id == tab.id }
    tabManager.selectWorkspace(tab)
    _ = tab.openOrFocusWorkspaceTasksSurface(focus: true)
}
