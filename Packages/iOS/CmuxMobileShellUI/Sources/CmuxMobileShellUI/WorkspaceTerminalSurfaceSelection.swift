import CmuxMobileBrowser
import CmuxMobileShell
import CmuxMobileShellModel

/// Atomically selects a terminal surface while retaining any hidden browser.
@MainActor
struct WorkspaceTerminalSurfaceSelection {
    let store: CMUXMobileShellStore
    let browserStore: BrowserSurfaceStore

    func selectFromSurfaceGrid(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) async -> MobileWorkspacePreview.ID? {
        guard let resolvedWorkspaceID = await store.openWorkspace(
            workspaceID,
            failureSelectionPolicy: .preserveSelection
        ),
              store.selectedWorkspaceID == resolvedWorkspaceID,
              let workspace = store.workspaces.first(where: { $0.id == resolvedWorkspaceID }),
              workspace.terminals.contains(where: { $0.id == terminalID }) else { return nil }
        selectFromChrome(
            terminalID: terminalID,
            browserWorkspaceIdentity: workspace.browserSurfaceIdentity
        )
        return resolvedWorkspaceID
    }

    func selectFromDeeplink(
        terminalID: MobileTerminalPreview.ID,
        browserWorkspaceIdentity: BrowserWorkspaceIdentity
    ) {
        browserStore.showNonBrowserSurface(for: browserWorkspaceIdentity)
        store.selectTerminal(terminalID)
    }

    func selectFromChrome(
        terminalID: MobileTerminalPreview.ID,
        browserWorkspaceIdentity: BrowserWorkspaceIdentity
    ) {
        browserStore.showNonBrowserSurface(for: browserWorkspaceIdentity)
        store.selectTerminalFromChrome(terminalID)
    }
}
