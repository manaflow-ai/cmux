import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileWorkspaceDiffAuthorizationTests {
    @Test func secondaryAuthorizationFailurePreservesForegroundConnection() async throws {
        let foregroundRouter = RoutingHostRouter()
        let secondaryRouter = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: foregroundRouter)
        store.connectionState = .connected
        try installSecondaryClient(
            on: store,
            macDeviceID: "mac-secondary",
            router: secondaryRouter
        )
        await secondaryRouter.setWorkspaceDiffErrorCode("forbidden")

        let foregroundWorkspace = MobileWorkspacePreview(
            id: "workspace-foreground",
            macDeviceID: "test-mac",
            name: "Foreground",
            terminals: []
        )
        let secondaryWorkspace = MobileWorkspacePreview(
            id: .init(rawValue: RoutingHostRouter.workspaceID),
            macDeviceID: "mac-secondary",
            name: "Secondary",
            terminals: []
        )
        store.setWorkspaceStatesForTesting([
            "test-mac": MacWorkspaceState(
                macDeviceID: "test-mac",
                workspaces: [foregroundWorkspace],
                status: .connected
            ),
            "mac-secondary": MacWorkspaceState(
                macDeviceID: "mac-secondary",
                workspaces: [secondaryWorkspace],
                status: .connected
            ),
        ], foregroundMacDeviceID: "test-mac")
        let secondaryWorkspaceID = try #require(
            store.workspaces.first { $0.macDeviceID == "mac-secondary" }?.id
        )
        let foregroundClient = try #require(store.remoteClient)

        await #expect(throws: MobileShellConnectionError.self) {
            try await store.fetchDiffStatus(workspaceID: secondaryWorkspaceID)
        }

        #expect(store.connectionState == .connected)
        #expect(store.remoteClient === foregroundClient)
        #expect(!store.connectionRequiresReauth)
        #expect(store.secondaryMacSubscriptions["mac-secondary"] == nil)
        #expect(store.workspacesByMac["mac-secondary"]?.status == .unavailable)
    }
}
