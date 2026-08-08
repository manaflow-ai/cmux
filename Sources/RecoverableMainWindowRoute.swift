import AppKit

@MainActor
final class RecoverableMainWindowRoute {
    let windowId: UUID
    private weak var weakTabManager: TabManager?
    private var retainedTabManager: TabManager?
    var tabManager: TabManager? { retainedTabManager ?? weakTabManager }
    weak var window: NSWindow?
    private var payload: RecoverableMainWindowRoutePayload
    var closeObserver: WindowCloseObserver?

    var sidebar: SidebarState? {
        guard case .live(let sidebar, _, _) = payload else { return nil }
        return sidebar
    }

    var sidebarSelection: SidebarSelectionState? {
        guard case .live(_, let sidebarSelection, _) = payload else { return nil }
        return sidebarSelection
    }

    var frozenWindowDockSnapshot: SessionSplitContainerSnapshot? {
        guard case .live(_, _, let snapshot) = payload else { return nil }
        return snapshot
    }

    var frozenWindowSnapshot: SessionWindowSnapshot? {
        guard case .frozen(let snapshot) = payload else { return nil }
        return snapshot
    }

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
        payload = .live(
            sidebar: sidebar,
            sidebarSelection: sidebarSelection,
            frozenWindowDockSnapshot: frozenWindowDockSnapshot
        )
    }

    /// Creates a persistence-only orphan without retaining any live window graph.
    init(
        windowId: UUID,
        frozenWindowSnapshot: SessionWindowSnapshot
    ) {
        self.windowId = windowId
        weakTabManager = nil
        retainedTabManager = nil
        window = nil
        payload = .frozen(frozenWindowSnapshot)
    }

    func markForTeardown() {
        retainedTabManager = nil
        payload = .teardown
        closeObserver = nil
    }
}
