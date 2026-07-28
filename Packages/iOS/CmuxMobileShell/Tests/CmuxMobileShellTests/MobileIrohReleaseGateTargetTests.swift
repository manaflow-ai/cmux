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
                status: .connected
            ),
            "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee": MacWorkspaceState(
                macDeviceID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                workspaces: [secondary],
                status: .connected
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
