import Foundation

@MainActor
final class GlobalHotkeyPanelContentState {
    let windowId: UUID
    let tabManager: TabManager
    let notificationStore: TerminalNotificationStore
    let sidebarState: SidebarState
    let sidebarSelectionState: SidebarSelectionState
    let fileExplorerState: FileExplorerState
    let cmuxConfigStore: CmuxConfigStore
    private var didScheduleConfigLoad = false

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
    }

    func scheduleConfigLoadAfterFirstDisplay() {
        guard !didScheduleConfigLoad else { return }
        didScheduleConfigLoad = true
        cmuxConfigStore.wireDirectoryTracking(
            tabManager: tabManager,
            loadsInitialConfiguration: false
        )
        let cmuxConfigStore = cmuxConfigStore
        DispatchQueue.main.async { [weak cmuxConfigStore] in
            cmuxConfigStore?.loadAll()
        }
    }
}
