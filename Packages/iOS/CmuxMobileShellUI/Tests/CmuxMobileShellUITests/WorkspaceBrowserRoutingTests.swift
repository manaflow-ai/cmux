import CmuxMobileBrowser
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell
@testable import CmuxMobileShellUI

@MainActor
@Suite struct WorkspaceBrowserRoutingTests {
    @Test func localBrowserDestinationDoesNotOpenRemoteWorkspace() {
        #expect(WorkspaceDetailOpenMode.localBrowser.opensRemoteWorkspace == false)
        #expect(WorkspaceDetailOpenMode.localBrowser.mountsRemoteWorkspaceSurface == false)
        #expect(WorkspaceDetailOpenMode.localBrowser.showsRemoteWorkspaceControls == false)
        #expect(WorkspaceDetailOpenMode.localBrowser.returnsToSurfaceGridOnBrowserClose)
        #expect(WorkspaceDetailOpenMode.remoteWorkspace.opensRemoteWorkspace)
        #expect(WorkspaceDetailOpenMode.remoteWorkspace.mountsRemoteWorkspaceSurface)
        #expect(WorkspaceDetailOpenMode.remoteWorkspace.showsRemoteWorkspaceControls)
        #expect(WorkspaceDetailOpenMode.remoteWorkspace.returnsToSurfaceGridOnBrowserClose == false)

        var performedActions: [String] = []
        WorkspaceDetailOpenMode.localBrowser.performRemoteAction {
            performedActions.append("wrong-client")
        }
        WorkspaceDetailOpenMode.remoteWorkspace.performRemoteAction {
            performedActions.append("attached-client")
        }
        #expect(performedActions == ["attached-client"])

        #expect(
            WorkspaceDetailOpenTaskID(workspaceID: "workspace-a", openMode: .remoteWorkspace)
                != WorkspaceDetailOpenTaskID(workspaceID: "workspace-b", openMode: .remoteWorkspace)
        )
        #expect(
            WorkspaceDetailOpenTaskID(workspaceID: "workspace-a", openMode: .localBrowser)
                != WorkspaceDetailOpenTaskID(workspaceID: "workspace-a", openMode: .remoteWorkspace)
        )
    }

    @Test func mixedIdentityReconciliationIncludesEveryVisibleWorkspace() {
        let workspaces = [
            workspace("anonymous", macDeviceID: nil),
            workspace("secondary", macDeviceID: "mac-b", status: .unavailable),
        ]

        let reconciliation = WorkspaceBrowserReconciliation(workspaces: workspaces)

        let browserStore = BrowserSurfaceStore(defaultURL: nil)
        let anonymousBrowser = browserStore.openBrowser(for: reconciliation.identities[0])
        let secondaryBrowser = browserStore.openBrowser(for: reconciliation.identities[1])
        _ = browserStore.openBrowser(for: "stale")
        browserStore.reconcileWorkspaces(reconciliation.identities)

        #expect(reconciliation.identities == [
            BrowserWorkspaceIdentity(rawValue: "anonymous"),
            BrowserWorkspaceIdentity(
                rawValue: "5:mac-b:secondary",
                aliases: ["secondary"]
            ),
        ])
        #expect(browserStore.browser(for: reconciliation.identities[0]) === anonymousBrowser)
        #expect(browserStore.browser(for: reconciliation.identities[1]) === secondaryBrowser)
        #expect(browserStore.browser(for: "stale") == nil)
    }

    @Test func surfaceGridTerminalSelectionWaitsForWorkspaceOpen() async throws {
        let store = CMUXMobileShellStore.preview()
        store.signIn()
        store.pairingCode = "debug"
        store.connectPreviewHost()
        let workspace = try #require(store.workspaces.first(where: { $0.id == "workspace-docs" }))
        let terminal = try #require(workspace.terminals.first)
        let browserStore = BrowserSurfaceStore(defaultURL: nil)
        _ = browserStore.openBrowser(for: workspace.browserSurfaceIdentity)

        let resolvedWorkspaceID = await WorkspaceTerminalSurfaceSelection(
            store: store,
            browserStore: browserStore
        ).selectFromSurfaceGrid(workspaceID: workspace.id, terminalID: terminal.id)

        #expect(resolvedWorkspaceID == workspace.id)
        #expect(store.selectedWorkspaceID == workspace.id)
        #expect(store.selectedTerminalID == terminal.id)
        #expect(browserStore.activeBrowser(for: workspace.browserSurfaceIdentity) == nil)
    }

    @Test func failedSurfaceGridWorkspaceOpenDoesNotExposeTerminal() async throws {
        let store = CMUXMobileShellStore.preview()
        let terminal = MobileTerminalPreview(id: "secondary-terminal", name: "Terminal")
        let secondaryWorkspace = MobileWorkspacePreview(
            id: "secondary-workspace",
            macDeviceID: "mac-b",
            name: "Secondary",
            terminals: [terminal]
        )
        store.setWorkspaceStatesForTesting([
            "mac-a": MacWorkspaceState(macDeviceID: "mac-a", workspaces: [], status: .connected),
            "mac-b": MacWorkspaceState(
                macDeviceID: "mac-b",
                workspaces: [secondaryWorkspace],
                status: .unavailable
            ),
        ], foregroundMacDeviceID: "mac-a")
        let workspace = try #require(store.workspaces.first)
        let browserStore = BrowserSurfaceStore(defaultURL: nil)
        let browser = browserStore.openBrowser(for: workspace.browserSurfaceIdentity)
        let priorTerminalID = store.selectedTerminalID

        let resolvedWorkspaceID = await WorkspaceTerminalSurfaceSelection(
            store: store,
            browserStore: browserStore
        ).selectFromSurfaceGrid(workspaceID: workspace.id, terminalID: terminal.id)

        #expect(resolvedWorkspaceID == nil)
        #expect(store.selectedTerminalID == priorTerminalID)
        #expect(browserStore.activeBrowser(for: workspace.browserSurfaceIdentity) === browser)
    }

    private func workspace(
        _ id: String,
        macDeviceID: String?,
        status: MobileMacConnectionStatus? = nil
    ) -> MobileWorkspacePreview {
        var workspace = MobileWorkspacePreview(
            id: .init(rawValue: id),
            macDeviceID: macDeviceID,
            name: id,
            terminals: []
        )
        workspace.macConnectionStatus = status
        return workspace
    }
}
