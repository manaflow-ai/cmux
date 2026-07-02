import Foundation

/// Owns every per-window Dock store.
///
/// All registry mutation lives here so the create/seed/teardown lifecycle cannot
/// be bypassed by out-of-band writes. `AppDelegate` holds one instance and
/// exposes read/lifecycle forwarding only.
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
