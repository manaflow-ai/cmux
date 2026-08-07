import AppKit

@MainActor
final class RecoverableMainWindowRoute {
    let windowId: UUID
    weak var tabManager: TabManager?
    weak var window: NSWindow?
    let sidebar: SidebarState
    let sidebarSelection: SidebarSelectionState
    private(set) var frozenWindowDockSnapshot: SessionSplitContainerSnapshot?
    let order: UInt64
    private(set) var purpose: RecoverableMainWindowRoutePurpose
    var closeObserver: WindowCloseObserver?

    init(
        windowId: UUID,
        tabManager: TabManager,
        window: NSWindow?,
        sidebar: SidebarState,
        sidebarSelection: SidebarSelectionState,
        frozenWindowDockSnapshot: SessionSplitContainerSnapshot?,
        purpose: RecoverableMainWindowRoutePurpose,
        order: UInt64
    ) {
        self.windowId = windowId
        self.tabManager = tabManager
        self.window = window
        self.sidebar = sidebar
        self.sidebarSelection = sidebarSelection
        self.frozenWindowDockSnapshot = frozenWindowDockSnapshot
        self.purpose = purpose
        self.order = order
    }

    func markForTeardown() {
        purpose = .teardownOnly
        frozenWindowDockSnapshot = nil
    }
}
