import CmuxMobileBrowser
import CmuxMobileShell
import CmuxMobileShellModel

/// Atomically selects a terminal surface while retaining any hidden browser.
@MainActor
struct WorkspaceTerminalSurfaceSelection {
    let store: CMUXMobileShellStore
    let browserStore: BrowserSurfaceStore

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
