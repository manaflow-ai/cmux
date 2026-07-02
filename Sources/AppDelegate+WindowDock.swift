import AppKit
import CmuxTerminal

extension AppDelegate.MainWindowContext {
    /// The Dock for this window, created on first access and retained until
    /// the context is unregistered. Seeded from `~/.config/cmux/dock.json`
    /// with a home base directory, like the app-wide Dock was on a fresh launch.
    func windowDockStore() -> DockSplitStore {
        if let existing = windowDock { return existing }
        let store = DockSplitStore(
            workspaceId: windowId,
            scope: .global,
            baseDirectoryProvider: { nil },
            remoteBrowserSettingsProvider: { .local }
        )
        windowDock = store
        return store
    }

    func existingWindowDock() -> DockSplitStore? {
        windowDock
    }

    /// Tears down this context's Dock, closing any live terminals/browsers and
    /// their portals, so no Dock panel outlives its window.
    func teardownWindowDock() {
        guard let dock = windowDock else { return }
        windowDock = nil
        dock.closeAllPanels()
    }
}

/// Per-window Docks.
///
/// Every main window hosts its own independent `DockSplitStore`: a window's
/// right-sidebar Dock panel mounts that window's store, created lazily the
/// first time the window shows the Dock and seeded from the global Dock config
/// (`~/.config/cmux/dock.json`) exactly like a fresh launch. A window's Dock —
/// including its live terminal/browser panels — is torn down when the window
/// unregisters, so no PTYs outlive their window.
///
/// Each store's `workspaceId` IS the owning window's `windowId`. That keeps the
/// registry a plain dictionary lookup and makes Dock-scoped CLI results
/// (`workspace_id`) self-describing: they name the window whose Dock they hit.

extension AppDelegate {
    /// Legacy Dock routing alias, kept for CLI compatibility with the retired
    /// app-wide Global Dock. A `workspace_id` equal to this constant means "the
    /// Dock" generically and resolves to the Dock of whichever window the rest
    /// of the routing selects (explicit `window_id`, else the caller's window).
    /// Nonisolated so socket routing can compare ids off the main actor.
    nonisolated static let windowDockAliasWorkspaceId = UUID(uuidString: "D0CCD0CC-0000-4000-8000-000000000001")!

    /// Whether `id` routes to a per-window Dock: either the legacy alias or the
    /// owner id (== window id) of a registered main window, even if that window's
    /// Dock store has not been lazily created yet.
    static func isWindowDockRoutingId(_ id: UUID) -> Bool {
        if id == windowDockAliasWorkspaceId { return true }
        return AppDelegate.shared?.mainWindowContext(forWindowId: id) != nil
    }

    private func mainWindowContext(forWindowId windowId: UUID) -> MainWindowContext? {
        mainWindowContexts.values.first { $0.windowId == windowId }
    }

    /// The Dock for the window `windowId`, created on first access and retained
    /// until that window unregisters.
    func windowDock(forWindowId windowId: UUID) -> DockSplitStore {
        guard let context = mainWindowContext(forWindowId: windowId) else {
            preconditionFailure("Window Dock requested for an unregistered main window")
        }
        return context.windowDockStore()
    }

    /// The Dock for a registered window-owner id, created on first access. `nil`
    /// means `windowId` is not a live window-Dock owner.
    func windowDockForRegisteredOwner(_ windowId: UUID) -> DockSplitStore? {
        mainWindowContext(forWindowId: windowId)?.windowDockStore()
    }

    /// The Dock of `tabManager`'s window, created on first access for a live
    /// registered window. A recoverable (already-closed) window never seeds a
    /// NEW Dock — its Dock was torn down with the window, and a fresh store
    /// would have no teardown owner, leaving headless panels running until
    /// quit. Only an existing store remains addressable during close races.
    func windowDock(for tabManager: TabManager) -> DockSplitStore? {
        if let context = mainWindowContexts.values.first(where: { $0.tabManager === tabManager }) {
            return context.windowDockStore()
        }
        guard let windowId = windowId(for: tabManager) else { return nil }
        return existingWindowDock(forWindowId: windowId)
    }

    /// The window's Dock if it already exists, without creating it.
    func existingWindowDock(forWindowId windowId: UUID) -> DockSplitStore? {
        mainWindowContext(forWindowId: windowId)?.existingWindowDock()
    }

    /// The `TabManager` owning the registered window Dock owner id `id`
    /// (== its window id), or `nil` when `id` is not a live window. Lets
    /// tab-manager resolution route a Dock-scoped `workspace_id` to the owning
    /// window before the Dock store itself has been created.
    func tabManagerForWindowDockOwner(_ id: UUID) -> TabManager? {
        mainWindowContext(forWindowId: id)?.tabManager
    }

    /// The Dock of `tabManager`'s window if it already exists, without creating it.
    func existingWindowDock(for tabManager: TabManager) -> DockSplitStore? {
        guard let windowId = windowId(for: tabManager) else { return nil }
        return existingWindowDock(forWindowId: windowId)
    }

    /// Every live per-window Dock store.
    var existingWindowDocks: [DockSplitStore] {
        var seen: Set<ObjectIdentifier> = []
        return mainWindowContexts.values.compactMap { context in
            guard seen.insert(ObjectIdentifier(context)).inserted else { return nil }
            return context.existingWindowDock()
        }
    }

    /// The window Dock whose tree contains `panelId`, if any.
    func windowDockContainingPanel(_ panelId: UUID) -> DockSplitStore? {
        existingWindowDocks.first { $0.containsPanel(panelId) }
    }

    /// The window Dock whose tree contains `paneId`, if any.
    func windowDockContainingPane(_ paneId: UUID) -> DockSplitStore? {
        existingWindowDocks.first { $0.containsPane(paneId) }
    }

    /// Routes a Ghostty runtime close (close binding, Ctrl-D child exit) for a
    /// window-Dock surface to its owning store. Returns `false` when the
    /// surface is not a window-Dock panel, so the caller falls through to the
    /// workspace path. Window-Dock owner ids are window ids, not workspace tab
    /// ids, so `TabManager.closeRuntimeSurface`-style routing cannot find them.
    @discardableResult
    func closeWindowDockRuntimeSurface(surfaceId: UUID, force: Bool) -> Bool {
        guard let dock = windowDockContainingPanel(surfaceId) else { return false }
        if dock.closePanel(surfaceId, force: force) {
            notificationStore?.clearNotifications(forTabId: dock.workspaceId, surfaceId: surfaceId)
        }
        return true
    }

    /// Tears down the window's Dock. Called when the owning window unregisters.
    ///
    /// Deliberately unconditional: window close is the containing lifecycle,
    /// and a busy Dock panel does not veto it — exactly like the window's
    /// workspace surfaces, which get no per-process veto on this path either.
    /// The menu close path shows the unconditional "Close window?" dialog, and
    /// the last-window/quit path is gated by
    /// `hasQuitConfirmationDirtyWorkspaces()`, which counts window Docks.
    func teardownWindowDock(forWindowId windowId: UUID) {
        mainWindowContext(forWindowId: windowId)?.teardownWindowDock()
    }

    /// Resolves the `TabManager` a Dock's cross-container moves should target.
    /// A Workspace Dock maps to its owning workspace's window; a window Dock
    /// maps to its owning window (its owner id IS that window's id). Fails
    /// closed (`nil`) when the owning window cannot be resolved — a move must
    /// never silently retarget a different window's tree.
    func dockReferenceTabManager(for dock: DockSplitStore) -> TabManager? {
        if dock.scope == .global {
            return tabManagerFor(windowId: dock.workspaceId)
        }
        return tabManagerFor(tabId: dock.workspaceId)
    }
}
