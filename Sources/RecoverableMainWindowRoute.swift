import AppKit

@MainActor
final class RecoverableMainWindowRoute {
    let windowId: UUID
    private weak var weakTabManager: TabManager?
    private var retainedTabManager: TabManager?
    private var retainedContext: AppDelegate.MainWindowContext?
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
        retainedContext?.teardownWindowDock()
        retainedContext = nil
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
        retainedContext = context
        retainedTabManager = nil
        return true
    }

    /// Returns a live orphan's original context without tearing down its graph.
    func takeContextForRegistration(
        matching proposedContext: AppDelegate.MainWindowContext
    ) -> AppDelegate.MainWindowContext? {
        guard let context = retainedContext,
              proposedContext.windowId == windowId,
              proposedContext.tabManager === context.tabManager,
              proposedContext.sidebarState === context.sidebarState,
              proposedContext.sidebarSelectionState === context.sidebarSelectionState else {
            return nil
        }
        if let routeWindow = window,
           routeWindow.isVisible || routeWindow.isMiniaturized {
            guard proposedContext.window === routeWindow else { return nil }
        } else if let routeWindow,
                  proposedContext.window !== routeWindow {
            // A hidden orphan can be replaced by a newly-created window with the
            // same stable id. Detach the old AppKit identity before the retained
            // context becomes live again so a later stale close cannot resolve the
            // replacement by identifier.
            routeWindow.identifier = nil
            context.closeObserver = nil
        }

        retainedContext = nil
        retainedTabManager = nil
        payload = .teardown
        closeObserver = nil
        return context
    }
}
