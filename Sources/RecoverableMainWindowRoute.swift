import AppKit

@MainActor
final class RecoverableMainWindowRoute {
    let windowId: UUID
    /// Workspace identities captured while the live owner is still available.
    /// Owner-deinit and stale-route retirement can use this bounded snapshot to
    /// detach remote mirrors even after the weak manager reference disappears.
    let workspaceIds: [UUID]
    private weak var weakTabManager: TabManager?
    private var retainedTabManager: TabManager?
    private weak var retainedContext: AppDelegate.MainWindowContext?
    private var retainedWindowDock: DockSplitStore?
    var tabManager: TabManager? {
        retainedContext?.tabManager ?? retainedTabManager ?? weakTabManager
    }
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

    var windowDock: MainWindowRouteDockState? {
        if let dock = retainedContext?.existingWindowDock() {
            return .live(dock)
        }
        if let retainedWindowDock, !retainedWindowDock.isRetired {
            return .live(retainedWindowDock)
        }
        return frozenWindowDockSnapshot.map { .frozen($0) }
    }

    /// Returns the live Dock owner when one still exists; frozen Dock state is
    /// intentionally value-only and cannot be used for live routing.
    var liveWindowDock: DockSplitStore? {
        guard case .live(let dock)? = windowDock else { return nil }
        return dock
    }

    /// Indicates whether this live route can occupy a persisted window slot.
    var isEligibleForSessionPersistence: Bool {
        if frozenWindowSnapshot != nil {
            return true
        }
        guard let manager = tabManager else { return false }
        let workspaces = manager.tabs
        let omitsRemoteMirrorOnlyWindow = windowDock == nil
            && !workspaces.isEmpty
            && workspaces.allSatisfy(\.isRemoteTmuxMirror)
        return !omitsRemoteMirrorOnlyWindow
    }

    var frozenWindowSnapshot: SessionWindowSnapshot? {
        guard case .frozen(let snapshot) = payload else { return nil }
        return snapshot
    }

    private func sidebarSelectionsMatch(
        _ lhs: SidebarSelection,
        _ rhs: SidebarSelection
    ) -> Bool {
        switch (lhs, rhs) {
        case (.tabs, .tabs), (.notifications, .notifications):
            return true
        default:
            return false
        }
    }

    init(
        windowId: UUID,
        tabManager: TabManager,
        window: NSWindow?,
        sidebar: SidebarState,
        sidebarSelection: SidebarSelectionState,
        frozenWindowDockSnapshot: SessionSplitContainerSnapshot?,
        retainTabManager: Bool,
        retainedWindowDock: DockSplitStore? = nil
    ) {
        self.windowId = windowId
        workspaceIds = tabManager.tabs.map(\.id)
        weakTabManager = tabManager
        retainedTabManager = retainTabManager ? tabManager : nil
        self.retainedWindowDock = retainedWindowDock
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
        workspaceIds = frozenWindowSnapshot.tabManager.workspaces.compactMap(\.workspaceId)
        weakTabManager = nil
        retainedTabManager = nil
        window = nil
        payload = .frozen(frozenWindowSnapshot)
    }

    func markForTeardown() {
        let contextDock = retainedContext?.existingWindowDock()
        retainedContext?.teardownWindowDock()
        retainedContext = nil
        if let retainedWindowDock,
           retainedWindowDock !== contextDock {
            retainedWindowDock.retire()
        }
        retainedWindowDock = nil
        retainedTabManager = nil
        payload = .teardown
        closeObserver = nil
    }

    /// Moves the registered context under this route's live ownership.
    func retainContextForOrphaning(_ context: AppDelegate.MainWindowContext) -> Bool {
        guard context.windowId == windowId,
              frozenWindowSnapshot == nil,
              context.tabManager === tabManager,
              context.sidebarState === sidebar,
              context.sidebarSelectionState === sidebarSelection else {
            return false
        }
        if let dock = context.detachWindowDockForContextReplacement() {
            if let retainedWindowDock, retainedWindowDock !== dock {
                retainedWindowDock.retire()
            }
            retainedWindowDock = dock
        }
        retainedContext = context
        return true
    }

    /// Returns a live orphan's original or proposed context without tearing down
    /// its graph. Standalone compatibility routes have no original context, so a
    /// value-matching replacement is adopted directly.
    func takeContextForRegistration(
        matching proposedContext: AppDelegate.MainWindowContext
    ) -> AppDelegate.MainWindowContext? {
        guard proposedContext.windowId == windowId,
              let routeSidebar = sidebar,
              let routeSelection = sidebarSelection,
              let routeManager = tabManager,
              proposedContext.tabManager === routeManager,
              proposedContext.sidebarState.isVisible == routeSidebar.isVisible,
              proposedContext.sidebarState.persistedWidth == routeSidebar.persistedWidth,
              sidebarSelectionsMatch(
                  proposedContext.sidebarSelectionState.selection,
                  routeSelection.selection
              ) else {
            return nil
        }
        if let routeWindow = window {
            if routeWindow.isVisible || routeWindow.isMiniaturized {
                guard proposedContext.window === routeWindow else { return nil }
            } else if proposedContext.window !== routeWindow {
                // A hidden orphan can be replaced by a newly-created window with
                // the same stable id. Detach the old AppKit identity before the
                // retained context becomes live again so a later stale close
                // cannot resolve the replacement by identifier.
                routeWindow.identifier = nil
            }
        }

        let context = retainedContext ?? proposedContext
        if context !== proposedContext {
            context.closeObserver = nil
        }
        if let retainedWindowDock {
            context.adoptRecoveredWindowDock(retainedWindowDock)
            self.retainedWindowDock = nil
        }
        retainedContext = nil
        retainedTabManager = nil
        payload = .teardown
        closeObserver = nil
        return context
    }
}
