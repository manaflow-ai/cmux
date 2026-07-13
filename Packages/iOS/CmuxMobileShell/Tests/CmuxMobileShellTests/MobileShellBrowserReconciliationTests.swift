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

    @Test func failedWorkspaceOpenPreservesSelectionByDefault() async throws {
        let (store, workspaceID) = try unavailableSecondaryWorkspaceStore()

        let resolvedID = await store.openWorkspace(workspaceID)

        #expect(resolvedID == nil)
        #expect(store.selectedWorkspaceID == workspaceID)
    }

    private func unavailableSecondaryWorkspaceStore() throws -> (
        store: MobileShellComposite,
        workspaceID: MobileWorkspacePreview.ID
    ) {
        let store = MobileShellComposite.preview()
        let secondaryWorkspace = MobileWorkspacePreview(
            id: "workspace-secondary",
            macDeviceID: "mac-b",
            name: "Secondary",
            terminals: []
        )
        store.setWorkspaceStatesForTesting([
            "mac-a": MacWorkspaceState(macDeviceID: "mac-a", workspaces: [], status: .connected),
            "mac-b": MacWorkspaceState(
                macDeviceID: "mac-b",
                workspaces: [secondaryWorkspace],
                status: .unavailable
            ),
        ], foregroundMacDeviceID: "mac-a")
        let workspaceID = try #require(store.workspaces.first?.id)
        store.selectedWorkspaceID = workspaceID
        return (store, workspaceID)
    }
}
