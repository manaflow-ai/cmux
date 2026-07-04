import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct CreatedTerminalOwnershipTests {
    @Test func createdTerminalPinDoesNotRetargetAfterForegroundReconnect() throws {
        let store = MobileShellComposite.preview()
        let aggregation = MobileWorkspaceAggregation()
        let remoteWorkspaceID = MobileWorkspacePreview.ID(rawValue: "shared-workspace")
        let macA = "mac-a"
        let macB = "mac-b"
        let otherMac = "mac-other"
        let rowA = aggregation.rowID(macDeviceID: macA, workspaceID: remoteWorkspaceID)
        let rowB = aggregation.rowID(macDeviceID: macB, workspaceID: remoteWorkspaceID)
        let fallbackB = MobileTerminalPreview.ID(rawValue: "terminal-b-ready")

        store.setWorkspaceStatesForTesting([
            macA: state(macDeviceID: macA, workspaceID: remoteWorkspaceID, terminals: [
                MobileTerminalPreview(id: "terminal-a-ready", name: "A", isReady: true),
            ]),
            otherMac: state(macDeviceID: otherMac, workspaceID: "other-workspace", terminals: [
                MobileTerminalPreview(id: "terminal-other", name: "Other", isReady: true),
            ]),
        ], foregroundMacDeviceID: macA)
        store.selectedWorkspaceID = rowA

        store.createTerminal(in: rowA)
        let created = try #require(store.selectedTerminalID)

        store.setWorkspaceStatesForTesting([
            macA: state(macDeviceID: macA, workspaceID: remoteWorkspaceID, terminals: [
                MobileTerminalPreview(id: "terminal-a-ready", name: "A", isReady: true),
                MobileTerminalPreview(id: created, name: "Created A", isReady: false),
            ]),
            otherMac: state(macDeviceID: otherMac, workspaceID: "other-workspace", terminals: [
                MobileTerminalPreview(id: "terminal-other", name: "Other", isReady: true),
            ]),
        ], foregroundMacDeviceID: nil)

        store.setWorkspaceStatesForTesting([
            macB: state(macDeviceID: macB, workspaceID: remoteWorkspaceID, terminals: [
                MobileTerminalPreview(id: fallbackB, name: "B", isReady: true),
                MobileTerminalPreview(id: created, name: "Created B", isReady: false),
            ]),
            otherMac: state(macDeviceID: otherMac, workspaceID: "other-workspace", terminals: [
                MobileTerminalPreview(id: "terminal-other", name: "Other", isReady: true),
            ]),
        ], foregroundMacDeviceID: macB)

        #expect(store.selectedWorkspaceID == rowB)
        #expect(store.selectedTerminalID == fallbackB)
        #expect(store.selectedTerminalID != created)
    }

    private func state(
        macDeviceID: String,
        workspaceID: MobileWorkspacePreview.ID,
        terminals: [MobileTerminalPreview]
    ) -> MacWorkspaceState {
        MacWorkspaceState(
            macDeviceID: macDeviceID,
            workspaces: [
                MobileWorkspacePreview(
                    id: workspaceID,
                    macDeviceID: macDeviceID,
                    name: macDeviceID,
                    terminals: terminals
                ),
            ],
            status: .connected
        )
    }
}
