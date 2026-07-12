import CmuxMobileBrowser
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceBrowserRoutingTests {
    @Test func localBrowserDestinationDoesNotOpenRemoteWorkspace() {
        #expect(WorkspaceDetailOpenMode.localBrowser.opensRemoteWorkspace == false)
        #expect(WorkspaceDetailOpenMode.remoteWorkspace.opensRemoteWorkspace)
    }

    @Test func mixedIdentityReconciliationIncludesEveryVisibleWorkspace() {
        let workspaces = [
            workspace("anonymous", macDeviceID: nil),
            workspace("secondary", macDeviceID: "mac-b", status: .unavailable),
        ]

        let reconciliation = WorkspaceBrowserReconciliation(workspaces: workspaces)

        #expect(reconciliation.identities == [
            BrowserWorkspaceIdentity(rawValue: "anonymous"),
            BrowserWorkspaceIdentity(
                rawValue: "5:mac-b:secondary",
                aliases: ["secondary"]
            ),
        ])
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
