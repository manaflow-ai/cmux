import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellBrowserReconciliationTests {
    @Test func reconciliationRequiresEverySecondaryMacSnapshot() {
        let store = MobileShellComposite.preview()
        store.setWorkspaceStatesForTesting([
            "mac-a": MacWorkspaceState(macDeviceID: "mac-a", workspaces: [], status: .connected),
        ], foregroundMacDeviceID: "mac-a")

        #expect(store.hasWorkspaceSnapshots(forSecondaryMacIDs: ["mac-b"]) == false)

        store.setWorkspaceStatesForTesting([
            "mac-a": MacWorkspaceState(macDeviceID: "mac-a", workspaces: [], status: .connected),
            "mac-b": MacWorkspaceState(macDeviceID: "mac-b", workspaces: [], status: .unavailable),
        ], foregroundMacDeviceID: "mac-a")

        #expect(store.hasWorkspaceSnapshots(forSecondaryMacIDs: ["mac-b"]))
    }

    @Test func openingWorkspaceReturnsItsCurrentRowIdentity() async {
        let store = MobileShellComposite.preview()
        store.signIn()
        store.pairingCode = "debug"
        store.connectPreviewHost()

        let resolvedID = await store.openWorkspace("workspace-docs")

        #expect(resolvedID == "workspace-docs")
        #expect(store.selectedWorkspaceID == resolvedID)
    }
}
