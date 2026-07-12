import CmuxMobileBrowser
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@MainActor
@Suite struct WorkspaceBrowserRoutingTests {
    @Test func localBrowserDestinationDoesNotOpenRemoteWorkspace() {
        #expect(WorkspaceDetailOpenMode.localBrowser.opensRemoteWorkspace == false)
        #expect(WorkspaceDetailOpenMode.localBrowser.mountsRemoteWorkspaceSurface == false)
        #expect(WorkspaceDetailOpenMode.localBrowser.showsRemoteWorkspaceControls == false)
        #expect(WorkspaceDetailOpenMode.remoteWorkspace.opensRemoteWorkspace)
        #expect(WorkspaceDetailOpenMode.remoteWorkspace.mountsRemoteWorkspaceSurface)
        #expect(WorkspaceDetailOpenMode.remoteWorkspace.showsRemoteWorkspaceControls)

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
