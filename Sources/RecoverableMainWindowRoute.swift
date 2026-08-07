import AppKit

@MainActor
final class RecoverableMainWindowRoute {
    let windowId: UUID
    private weak var weakTabManager: TabManager?
    private var retainedTabManager: TabManager?
    var tabManager: TabManager? { retainedTabManager ?? weakTabManager }
    weak var window: NSWindow?
    let sidebar: SidebarState
    let sidebarSelection: SidebarSelectionState
    private(set) var frozenWindowDockSnapshot: SessionSplitContainerSnapshot?
    var closeObserver: WindowCloseObserver?

    init(
        windowId: UUID,
        tabManager: TabManager,
        window: NSWindow?,
        sidebar: SidebarState,
        sidebarSelection: SidebarSelectionState,
        frozenWindowDockSnapshot: SessionSplitContainerSnapshot?,
        retainTabManager: Bool
    ) {
        self.windowId = windowId
        weakTabManager = tabManager
        retainedTabManager = retainTabManager ? tabManager : nil
        self.window = window
        self.sidebar = sidebar
        self.sidebarSelection = sidebarSelection
        self.frozenWindowDockSnapshot = frozenWindowDockSnapshot
    }

    func markForTeardown() {
        retainedTabManager = nil
        frozenWindowDockSnapshot = nil
        closeObserver = nil
    }
}
