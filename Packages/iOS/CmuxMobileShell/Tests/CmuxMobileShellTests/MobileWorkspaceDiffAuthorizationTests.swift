import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileWorkspaceDiffAuthorizationTests {
    @Test func workspaceDiffResponseDecodingLeavesMainThread() async throws {
        let statusData = Data(#"{"repo_root":"/tmp/repo","files":[]}"#.utf8)
        let fileData = Data(#"{"path":"A.swift","unified_diff":"+new"}"#.utf8)

        let ranOnMainThread = try await MobileShellComposite.decodeWorkspaceDiffResponse {
            _ = try MobileWorkspaceDiffStatusResponse.decode(statusData)
            _ = try MobileWorkspaceDiffFileResponse.decode(fileData)
            return Thread.isMainThread
        }

        #expect(!ranOnMainThread)
    }

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

    @Test func staleForegroundAuthorizationFailurePreservesReplacementConnection() async throws {
        let staleRouter = RoutingHostRouter()
        let replacementRouter = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: staleRouter)
        store.connectionState = .connected
        store.macConnectionStatus = .connected
        let workspaceID = try #require(store.workspaces.first?.id)
        let staleTarget = store.workspaceMutationTarget(for: workspaceID)
        try installFreshRemoteClient(on: store, router: replacementRouter)
        let replacementClient = try #require(store.remoteClient)

        let handled = store.disconnectForAuthorizationFailureIfNeeded(
            MobileShellConnectionError.rpcError("forbidden", "diff status rejected"),
            target: staleTarget
        )

        #expect(handled)
        #expect(store.connectionState == .connected)
        #expect(store.remoteClient === replacementClient)
        #expect(!store.connectionRequiresReauth)
        #expect(store.macConnectionStatus == .connected)
    }

    @Test func staleForegroundTransportFailurePreservesReplacementAvailability() async throws {
        let staleRouter = RoutingHostRouter()
        let replacementRouter = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: staleRouter)
        store.connectionState = .connected
        store.macConnectionStatus = .connected
        let workspaceID = try #require(store.workspaces.first?.id)
        let staleTarget = store.workspaceMutationTarget(for: workspaceID)
        try installFreshRemoteClient(on: store, router: replacementRouter)
        let replacementClient = try #require(store.remoteClient)

        store.markMacConnectionUnavailableIfNeeded(
            after: MobileShellConnectionError.connectionClosed,
            target: staleTarget
        )

        #expect(store.connectionState == .connected)
        #expect(store.remoteClient === replacementClient)
        #expect(store.macConnectionStatus == .connected)
        #expect(!store.connectionRecoveryFailed)
    }
}
