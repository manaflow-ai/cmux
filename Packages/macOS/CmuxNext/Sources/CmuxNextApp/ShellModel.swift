import Foundation
import Observation

/// One tab in the placeholder strip. Real tabs are projections of cmux-tui
/// daemon state; this exists only so the scaffold shows the chrome.
struct TabItem: Identifiable, Hashable {
    let id: UUID
    var title: String
}

struct WorkspaceItem: Identifiable, Hashable {
    let id: UUID
    var title: String
}

/// Frontend-only shell state for one window: sidebar visibility, the
/// placeholder tabs, and selection. Topology moves to daemon-backed stores
/// once CmuxNextDaemon has a real client.
@Observable
final class ShellModel {
    var isSidebarVisible = true
    private(set) var workspaces: [WorkspaceItem]
    var selectedWorkspaceID: WorkspaceItem.ID?
    private(set) var tabs: [TabItem] = []
    var selectedTabID: TabItem.ID?

    @ObservationIgnored private var tabCounter = 0

    init() {
        let workspace = WorkspaceItem(id: UUID(), title: Strings.defaultWorkspace)
        workspaces = [workspace]
        selectedWorkspaceID = workspace.id
        addTab()
    }

    func addTab() {
        tabCounter += 1
        let tab = TabItem(id: UUID(), title: Strings.tabTitle(tabCounter))
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func closeSelectedTab() {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        tabs.remove(at: index)
        selectedTabID = tabs[min(index, tabs.count - 1)].id
    }

    var canCloseTab: Bool { tabs.count > 1 }

    func selectAdjacentTab(offset: Int) {
        guard !tabs.isEmpty, let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        let next = (index + offset + tabs.count) % tabs.count
        selectedTabID = tabs[next].id
    }
}
