import CmuxControlSocket
import CmuxPanes
import CmuxSettings
import CmuxWorkspaces
import Foundation

/// Workspace sizing mutates AppKit/Ghostty state on the main actor while
/// preserving the caller's focus and selection.
extension TerminalController {
    // MARK: - Font size

    func controlWorkspaceFontSizeStrings() -> ControlWorkspaceFontSizeStrings {
        ControlWorkspaceFontSizeStrings(
            invalidParams: String(localized: "socket.workspace.fontSize.invalidParams", defaultValue: "Use increase, decrease, or reset with optional window_id and workspace_id selectors."),
            unavailable: String(localized: "socket.workspace.fontSize.unavailable", defaultValue: "Workspace font-size coordinator unavailable."),
            notFound: String(localized: "socket.workspace.fontSize.notFound", defaultValue: "Workspace not found in the requested window."),
            rejected: String(localized: "socket.workspace.fontSize.rejected", defaultValue: "Workspace font-size request was not accepted.")
        )
    }

    /// Shares the keyboard shortcut coordinator. Admission may queue behind
    /// a panel transfer, so acceptance does not imply completion.
    func controlWorkspaceFontSize(
        routing: ControlRoutingSelectors,
        action: ControlWorkspaceFontSizeAction
    ) -> ControlWorkspaceFontSizeResolution {
        guard let tabManager = resolveTabManager(routing: routing),
              let appDelegate = AppDelegate.shared else { return .unavailable }
        guard let workspace = resolveWorkspace(routing: routing, tabManager: tabManager) else {
            return .notFound
        }
        let shortcut: KeyboardShortcutSettings.Action
        switch action {
        case .increase: shortcut = .increaseWorkspaceTerminalFontSize
        case .decrease: shortcut = .decreaseWorkspaceTerminalFontSize
        case .reset: shortcut = .resetWorkspaceTerminalFontSize
        }
        switch appDelegate.enqueueWorkspaceTerminalFontSizeChange(
            shortcut, workspace: workspace, tabManager: tabManager, deferFlush: false
        ) {
        case .acceptedMutation: return .accepted(workspaceID: workspace.id)
        case .consumedWithoutMutation: return .unavailable
        case .rejected: return .rejected
        }
    }

    // MARK: - Equalize

    func controlEqualizeWorkspaceSplits(
        routing: ControlRoutingSelectors,
        orientationFilter: String?
    ) -> ControlWorkspaceEqualizeResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let ws = resolveWorkspace(routing: routing, tabManager: tabManager) else {
            return .notFound
        }
        let tree = ws.bonsplitController.treeSnapshot()
        let equalizeResult = tabManager.paneLayout.equalizeSplits(
            in: tree,
            controller: ws.bonsplitController,
            orientationFilter: orientationFilter
        )
        return .resolved(workspaceID: ws.id, equalized: equalizeResult.didFullyEqualize)
    }

    /// Mirrors the legacy `v2ResolveWorkspace(params:tabManager:)` precedence
    /// using the pre-resolved routing selectors: workspace, then surface, then
    /// pane (same TabManager), then the selected workspace.
    private func resolveWorkspace(
        routing: ControlRoutingSelectors,
        tabManager: TabManager
    ) -> Workspace? {
        if let workspaceId = routing.workspaceID {
            return tabManager.tabs.first(where: { $0.id == workspaceId })
        }
        if let surfaceId = routing.surfaceID {
            return tabManager.tabs.first(where: { $0.panels[surfaceId] != nil })
        }
        if let paneId = routing.paneID,
           let located = v2LocatePane(paneId) {
            guard located.tabManager === tabManager else { return nil }
            return located.workspace
        }
        guard let workspaceId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == workspaceId })
    }
}
