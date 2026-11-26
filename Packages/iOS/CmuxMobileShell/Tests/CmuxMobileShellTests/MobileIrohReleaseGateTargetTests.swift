import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileIrohReleaseGateTargetTests {
    @Test func releaseGateTargetsForegroundMacWhenAnotherMacIsSelected() throws {
        let store = MobileShellComposite.preview()
        let foreground = workspace(
            id: "foreground-workspace",
            macDeviceID: "11111111-2222-4333-8444-555555555555",
            terminalID: "foreground-terminal"
        )
        let secondary = workspace(
            id: "secondary-workspace",
            macDeviceID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            terminalID: "secondary-terminal"
        )
        store.setWorkspaceStatesForTesting([
            "11111111-2222-4333-8444-555555555555": MacWorkspaceState(
                macDeviceID: "11111111-2222-4333-8444-555555555555",
                workspaces: [foreground],
                status: .connected,
                actionCapabilities: MobileWorkspaceActionCapabilities(
                    supportsWorkspaceActions: true
                )
            ),
            "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee": MacWorkspaceState(
                macDeviceID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                workspaces: [secondary],
                status: .connected,
                actionCapabilities: MobileWorkspaceActionCapabilities(
                    supportsWorkspaceActions: true
                )
            ),
        ], foregroundMacDeviceID: "11111111-2222-4333-8444-555555555555")
        store.selectedWorkspaceID = try #require(
            store.workspaces.first(where: {
                $0.macDeviceID == "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
            })
        ).id

        let target = try #require(store.irohReleaseGateForegroundTarget())

        #expect(target.workspace.macDeviceID == "11111111-2222-4333-8444-555555555555")
        #expect(target.terminalID.rawValue == "foreground-terminal")
    }

    @Test func releaseGateReacquiresWorkspaceAfterAggregatedRowIdentityChanges() throws {
        let store = MobileShellComposite.preview()
        var initial = workspace(
            id: "initial-row-id",
            macDeviceID: "11111111-2222-4333-8444-555555555555",
            terminalID: "foreground-terminal"
        )
        initial.remoteWorkspaceID = "mac-local-workspace"
        store.setWorkspaceStatesForTesting([
            "11111111-2222-4333-8444-555555555555": MacWorkspaceState(
                macDeviceID: "11111111-2222-4333-8444-555555555555",
                workspaces: [initial],
                status: .connected,
                actionCapabilities: MobileWorkspaceActionCapabilities(
                    supportsWorkspaceActions: true
                )
            ),
        ], foregroundMacDeviceID: "11111111-2222-4333-8444-555555555555")
        let captured = try #require(store.irohReleaseGateForegroundTarget()?.workspace)

        var current = initial
        current.id = "reconciled-row-id"
        store.setWorkspaceStatesForTesting([
            "11111111-2222-4333-8444-555555555555": MacWorkspaceState(
                macDeviceID: "11111111-2222-4333-8444-555555555555",
                workspaces: [current],
                status: .connected,
                actionCapabilities: MobileWorkspaceActionCapabilities(
                    supportsWorkspaceActions: true
                )
            ),
        ], foregroundMacDeviceID: "11111111-2222-4333-8444-555555555555")

        let reacquired = try #require(
            store.irohReleaseGateCurrentWorkspace(matching: captured)
        )

        #expect(reacquired.id == "reconciled-row-id")
        #expect(reacquired.rpcWorkspaceID == "mac-local-workspace")
    }

    private func workspace(
        id: MobileWorkspacePreview.ID,
        macDeviceID: String,
        terminalID: MobileTerminalPreview.ID
    ) -> MobileWorkspacePreview {
        var workspace = MobileWorkspacePreview(
            id: id,
            macDeviceID: macDeviceID,
            name: id.rawValue,
            terminals: [MobileTerminalPreview(id: terminalID, name: terminalID.rawValue)]
        )
        workspace.actionCapabilities = MobileWorkspaceActionCapabilities(
            supportsWorkspaceActions: true
        )
        return workspace
    }
}
