import CmuxCloud
import Foundation

extension AppDelegate {
    /// Keeps focus and workspace teardown with the live app owner at effect time.
    static func makeCloudTerminalNavigationHost() -> CloudTerminalNavigationHost {
        CloudTerminalNavigationHost(
            focus: { panelID, workspaceID in SurfacePaneFactory.focus(panelID: panelID, in: workspaceID) },
            closeWorkspace: { workspaceID in
                guard let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID),
                      let workspace = manager.tabs.first(where: { $0.id == workspaceID }) else { return }
                _ = manager.closeWorkspaceNonInteractively(workspace, recordHistory: false, allowPinned: true)
            }
        )
    }

    /// Selects a local workspace from a Cloud tree row in the window that owns it.
    ///
    /// Every window's Cloud tree reads the app-wide surface catalog, so a row
    /// can point at a workspace that another window owns. Selecting it on the
    /// panel's own manager would do nothing, so route to the owner and bring
    /// that window forward (#19967).
    /// - Parameters:
    ///   - workspaceID: The local workspace the row resolved to.
    ///   - panelManager: The manager of the window whose Cloud tree was used.
    ///   - focusWindow: Brings a main window forward; defaults to ``focusMainWindow(windowId:)``.
    /// - Returns: Whether the workspace was selected, is open in a window that
    ///   could not be brought forward, or has no live owner.
    @discardableResult
    func selectCloudTreeLocalWorkspace(
        _ workspaceID: UUID,
        from panelManager: TabManager?,
        focusWindow: ((UUID) -> Bool)? = nil
    ) -> CloudTreeLocalWorkspaceSelection {
        let owner = tabManagerFor(tabId: workspaceID)
            ?? panelManager.flatMap { $0.workspacesById[workspaceID] != nil ? $0 : nil }
        guard let owner, !owner.isFinalizedForWindowClose else { return .notOpen }
        if owner !== panelManager, let windowId = owner.windowId {
            let didFocus = focusWindow?(windowId) ?? focusMainWindow(windowId: windowId)
            // A window that cannot come forward (a committed close or a lost
            // route) still holds the workspace, so callers must not open a copy.
            guard didFocus else { return .openInUnfocusableWindow }
        }
        owner.focusTab(workspaceID, suppressFlash: true, dismissRestoredUnreadOnResume: true)
        return .selected
    }
}

/// The outcome of selecting a Cloud tree row's local workspace.
enum CloudTreeLocalWorkspaceSelection: Equatable {
    /// Selected in its owning window, which is now in front.
    case selected
    /// Open in another window that could not be brought forward; nothing changed.
    case openInUnfocusableWindow
    /// No live window owns it, so the caller may open it.
    case notOpen
}
