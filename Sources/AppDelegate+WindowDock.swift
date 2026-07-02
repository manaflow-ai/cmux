import AppKit
import CmuxTerminal

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
    static let windowDockAliasWorkspaceId = UUID(uuidString: "D0CCD0CC-0000-4000-8000-000000000001")!

    /// Whether `id` routes to a per-window Dock: either the legacy alias or the
    /// owner id (== window id) of a live window Dock.
    static func isWindowDockRoutingId(_ id: UUID) -> Bool {
        if id == windowDockAliasWorkspaceId { return true }
        return AppDelegate.shared?.existingWindowDock(forWindowId: id) != nil
    }

    /// The Dock for the window `windowId`, created on first access and retained
    /// until that window unregisters.
    func windowDock(forWindowId windowId: UUID) -> DockSplitStore {
        windowDockRegistry.dock(forWindowId: windowId)
    }

    /// The Dock of `tabManager`'s window, created on first access for a live
    /// registered window. A recoverable (already-closed) window never seeds a
    /// NEW Dock — its Dock was torn down with the window, and a fresh store
    /// would have no teardown owner, leaving headless panels running until
    /// quit. Only an existing store remains addressable during close races.
    func windowDock(for tabManager: TabManager) -> DockSplitStore? {
        if let context = mainWindowContexts.values.first(where: { $0.tabManager === tabManager }) {
            return windowDock(forWindowId: context.windowId)
        }
        guard let windowId = windowId(for: tabManager) else { return nil }
        return existingWindowDock(forWindowId: windowId)
    }

    /// The window's Dock if it already exists, without creating it.
    func existingWindowDock(forWindowId windowId: UUID) -> DockSplitStore? {
        windowDockRegistry.existingDock(forWindowId: windowId)
    }

    /// The `TabManager` owning the live window Dock whose owner id is `id`
    /// (== its window id), or `nil` when `id` is not a live Dock owner. Lets
    /// tab-manager resolution route a Dock-scoped `workspace_id` to the owning
    /// window instead of the caller's.
    func tabManagerForWindowDockOwner(_ id: UUID) -> TabManager? {
        guard existingWindowDock(forWindowId: id) != nil else { return nil }
        return tabManagerFor(windowId: id)
    }

    /// The Dock of `tabManager`'s window if it already exists, without creating it.
    func existingWindowDock(for tabManager: TabManager) -> DockSplitStore? {
        guard let windowId = windowId(for: tabManager) else { return nil }
        return windowDockRegistry.existingDock(forWindowId: windowId)
    }

    /// Every live per-window Dock store.
    var existingWindowDocks: [DockSplitStore] {
        windowDockRegistry.allDocks
    }

    /// The window Dock whose tree contains `panelId`, if any.
    func windowDockContainingPanel(_ panelId: UUID) -> DockSplitStore? {
        windowDockRegistry.dockContainingPanel(panelId)
    }

    /// The window Dock whose tree contains `paneId`, if any.
    func windowDockContainingPane(_ paneId: UUID) -> DockSplitStore? {
        windowDockRegistry.dockContainingPane(paneId)
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
        windowDockRegistry.teardownDock(forWindowId: windowId)
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
