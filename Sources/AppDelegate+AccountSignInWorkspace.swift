import AppKit

extension AppDelegate {
    /// Opens the shared Stack sign-in flow in a dedicated workspace pane.
    @discardableResult
    func performAccountSignInWorkspaceAction(
        tabManager preferredTabManager: TabManager? = nil,
        preferredWindow: NSWindow? = nil,
        debugSource: String = "accountSignIn"
    ) -> Bool {
        guard CmuxFeatureFlags.shared.isSidebarAccountButtonEnabled else {
#if DEBUG
            cmuxDebugLog("accountSignIn.blocked_flag source=\(debugSource)")
#endif
            return false
        }
        guard let flow = auth?.accountFlow,
              let manager = preferredTabManager
                ?? synchronizeActiveMainWindowContext(preferredWindow: preferredWindow) else {
            return false
        }

        if let workspace = manager.tabs.first(where: { workspace in
            workspace.panels.values.contains { $0 is AccountSignInPanel }
        }), let panel = workspace.panels.values.first(where: { $0 is AccountSignInPanel }) as? AccountSignInPanel {
            manager.selectedTabId = workspace.id
            workspace.focusPanel(panel.id)
            panel.model.presentSignIn()
            return true
        }

        let title = String(localized: "account.signIn.workspace.title", defaultValue: "Sign In")
        let workspace = manager.addWorkspace(
            title: title,
            select: true,
            eagerLoadTerminal: false,
            autoWelcomeIfNeeded: false,
            autoRefreshMetadata: false,
            allowTextBoxFocusDefault: false
        )
        guard let initialPanelID = workspace.focusedPanelId,
              let paneID = workspace.paneId(forPanelId: initialPanelID),
              let panel = workspace.newAccountSignInSurface(inPane: paneID, flow: flow, focus: true) else {
            manager.closeWorkspace(workspace, recordHistory: false)
            return false
        }
        _ = workspace.closePanel(initialPanelID, force: true)
        panel.model.presentSignIn()
        return true
    }
}
