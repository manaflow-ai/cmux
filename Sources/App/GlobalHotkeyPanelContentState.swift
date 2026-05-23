import Foundation

@MainActor
struct GlobalHotkeyPanelContentState {
    let windowId: UUID
    let tabManager: TabManager
    let notificationStore: TerminalNotificationStore
    let sidebarState: SidebarState
    let sidebarSelectionState: SidebarSelectionState
    let fileExplorerState: FileExplorerState
    let cmuxConfigStore: CmuxConfigStore

    init(
        windowId: UUID = UUID(),
        tabManager: TabManager? = nil,
        notificationStore: TerminalNotificationStore? = nil,
        sidebarState: SidebarState? = nil,
        sidebarSelectionState: SidebarSelectionState? = nil,
        fileExplorerState: FileExplorerState? = nil,
        cmuxConfigStore: CmuxConfigStore? = nil
    ) {
        let resolvedTabManager = tabManager ?? TabManager(autoWelcomeIfNeeded: true)
        let resolvedConfigStore = cmuxConfigStore ?? CmuxConfigStore()

        self.windowId = windowId
        self.tabManager = resolvedTabManager
        self.notificationStore = notificationStore ?? TerminalNotificationStore.shared
        self.sidebarState = sidebarState ?? SidebarState()
        self.sidebarSelectionState = sidebarSelectionState ?? SidebarSelectionState()
        self.fileExplorerState = fileExplorerState ?? FileExplorerState()
        self.cmuxConfigStore = resolvedConfigStore

        resolvedConfigStore.wireDirectoryTracking(tabManager: resolvedTabManager)
        resolvedConfigStore.loadAll()
    }
}
