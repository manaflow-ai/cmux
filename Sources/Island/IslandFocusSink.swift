// Sources/Island/IslandFocusSink.swift

import AppKit
import Foundation

/// The exact set of cmux actions `IslandJumpRouter` needs to perform when
/// the user clicks a session row. Confining these behind a protocol makes
/// the router unit-testable and is also the single place where the Island
/// module writes back into cmux core state.
@MainActor
protocol IslandFocusSink: AnyObject {
    /// Bring cmux to the front (an explicit user intent that satisfies
    /// the socket focus-steal policy — see CLAUDE.md §"Socket focus policy").
    func activateApp()

    /// Select the workspace with the given id. Returns false if the
    /// workspace no longer exists.
    @discardableResult
    func selectWorkspace(id: UUID) -> Bool

    /// Focus the panel with the given id inside the previously-selected
    /// workspace. Returns false if the panel no longer exists.
    @discardableResult
    func focusPanel(id: UUID, inWorkspace workspaceId: UUID) -> Bool

    /// Collapse the island overlay (close the expanded panel).
    func collapseIsland()
}

/// Production implementation that routes through the live `TabManager`
/// and its workspaces. The `collapse` closure is injected so the sink
/// doesn't take a direct reference to the window controller — this keeps
/// the dependency flow one-directional.
@MainActor
final class TabManagerIslandFocusSink: IslandFocusSink {

    private let tabManager: TabManager
    private let collapse: @MainActor () -> Void

    init(tabManager: TabManager, collapse: @escaping @MainActor () -> Void) {
        self.tabManager = tabManager
        self.collapse = collapse
    }

    func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }

    @discardableResult
    func selectWorkspace(id: UUID) -> Bool {
        guard let workspace = tabManager.tabs.first(where: { $0.id == id }) else {
            return false
        }
        tabManager.selectWorkspace(workspace)
        return true
    }

    @discardableResult
    func focusPanel(id panelId: UUID, inWorkspace workspaceId: UUID) -> Bool {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }),
              workspace.panels[panelId] != nil else {
            return false
        }
        workspace.focusPanel(panelId)
        return true
    }

    func collapseIsland() {
        collapse()
    }
}
