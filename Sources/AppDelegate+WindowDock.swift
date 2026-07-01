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

/// Owns every per-window Dock store. All registry mutation lives here so the
/// create/seed/teardown lifecycle cannot be bypassed by out-of-band writes;
/// `AppDelegate` holds one instance and exposes read/lifecycle forwarding only.
@MainActor
final class WindowDockRegistry {
    private var docksByWindowId: [UUID: DockSplitStore] = [:]

    /// The Dock for the window `windowId`, created on first access and retained
    /// until `teardownDock(forWindowId:)`. Seeded from `~/.config/cmux/dock.json`
    /// with a home base directory, like the app-wide Dock was on a fresh launch.
    func dock(forWindowId windowId: UUID) -> DockSplitStore {
        if let existing = docksByWindowId[windowId] { return existing }
        let store = DockSplitStore(
            workspaceId: windowId,
            scope: .global,
            baseDirectoryProvider: { nil },
            remoteBrowserSettingsProvider: { .local }
        )
        docksByWindowId[windowId] = store
        return store
    }

    func existingDock(forWindowId windowId: UUID) -> DockSplitStore? {
        docksByWindowId[windowId]
    }

    var allDocks: [DockSplitStore] {
        Array(docksByWindowId.values)
    }

    func dockContainingPanel(_ panelId: UUID) -> DockSplitStore? {
        docksByWindowId.values.first(where: { $0.containsPanel(panelId) })
    }

    func dockContainingPane(_ paneId: UUID) -> DockSplitStore? {
        docksByWindowId.values.first(where: { $0.containsPane(paneId) })
    }

    /// Tears down the window's Dock (closing its terminals/browsers and their
    /// portals) and drops it from the registry, so a per-window Dock never
    /// outlives its window.
    func teardownDock(forWindowId windowId: UUID) {
        guard let dock = docksByWindowId.removeValue(forKey: windowId) else { return }
        dock.closeAllPanels()
    }
}

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

    /// The Dock of `tabManager`'s window, created on first access. `nil` only
    /// when the manager has no resolvable window (not registered, no
    /// recoverable route).
    func windowDock(for tabManager: TabManager) -> DockSplitStore? {
        guard let windowId = windowId(for: tabManager) else { return nil }
        return windowDock(forWindowId: windowId)
    }

    /// The window's Dock if it already exists, without creating it.
    func existingWindowDock(forWindowId windowId: UUID) -> DockSplitStore? {
        windowDockRegistry.existingDock(forWindowId: windowId)
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

    /// Tears down the window's Dock. Called when the owning window unregisters.
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
