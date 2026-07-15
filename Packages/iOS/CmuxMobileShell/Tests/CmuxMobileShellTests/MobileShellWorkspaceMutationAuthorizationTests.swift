import CmuxMobileRPC
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellWorkspaceMutationAuthorizationTests {
    @Test func secondaryWorkspaceCloseAuthorizationFailureInvalidatesOnlySecondaryOwner() async throws {
        try await assertSecondaryAuthorizationFailure(action: .close)
    }

    @Test func secondaryWorkspaceReorderAuthorizationFailureInvalidatesOnlySecondaryOwner() async throws {
        try await assertSecondaryAuthorizationFailure(action: .reorder)
    }

    @Test func lateReplacedForegroundAuthorizationFailureCannotDisconnectCurrentOwner() async throws {
        let rejectedRouter = RoutingHostRouter()
        let replacementRouter = RoutingHostRouter()
        await rejectedRouter.setWorkspaceMutationErrorCode("unauthorized")
        await rejectedRouter.setHoldFirstWorkspaceMutation(true)
        let capabilities = MobileWorkspaceActionCapabilities(supportsCloseActions: true)
        let store = try await makeRoutingConnectedStore(
            router: rejectedRouter,
            connectionState: .connected,
            workspaceActionCapabilities: capabilities
        )
        let sourceWorkspace = try #require(store.workspaces.first)
        let rejectedWorkspaceID = sourceWorkspace.id

        let mutation = Task { @MainActor in
            await store.closeWorkspace(id: rejectedWorkspaceID)
        }
        await rejectedRouter.awaitFirstWorkspaceMutationReached()

        try installFreshRemoteClient(on: store, router: replacementRouter)
        let replacementClient = try #require(store.remoteClient)
        store.connectedHostName = "Replacement Mac"
        var replacementWorkspace = sourceWorkspace
        replacementWorkspace.macDeviceID = "test-mac-2"
        replacementWorkspace.macDisplayName = "Replacement Mac"
        store.setWorkspaceStatesForTesting(
            [
                "test-mac-2": MacWorkspaceState(
                    macDeviceID: "test-mac-2",
                    displayName: "Replacement Mac",
                    workspaces: [replacementWorkspace],
                    status: .connected,
                    actionCapabilities: capabilities
                ),
            ],
            foregroundMacDeviceID: "test-mac-2"
        )

        await rejectedRouter.releaseFirstWorkspaceMutation()
        let result = await mutation.value

        if case .success = result {
            // Expected: the request no longer owns the foreground connection.
        } else {
            Issue.record("stale foreground rejection should be ignored: \(result)")
        }
        #expect(store.remoteClient === replacementClient)
        #expect(store.connectionState == .connected)
        #expect(store.macConnectionStatus == .connected)
        #expect(!store.connectionRequiresReauth)
        #expect(store.foregroundMacDeviceID == "test-mac-2")
        let rejectedMethods = await rejectedRouter.recordedWorkspaceMutationMethods()
        #expect(!rejectedMethods.isEmpty)
        #expect(rejectedMethods.allSatisfy { $0 == "workspace.close" })
        #expect(await replacementRouter.recordedWorkspaceMutationMethods().isEmpty)
    }

    @Test func authorizationInvalidatorRejectsStaleForegroundOwnerDirectly() async throws {
        let rejectedRouter = RoutingHostRouter()
        let replacementRouter = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: rejectedRouter,
            connectionState: .connected,
            workspaceActionCapabilities: MobileWorkspaceActionCapabilities(
                supportsCloseActions: true
            )
        )
        let workspaceID = try #require(store.workspaces.first?.id)
        let rejectedTarget = store.workspaceMutationTarget(for: workspaceID)
        let rejectedClient = try #require(rejectedTarget.client)
        let rejectedGeneration = store.connectionGeneration

        try installFreshRemoteClient(on: store, router: replacementRouter)
        let replacementClient = try #require(store.remoteClient)

        let handled = store.invalidateWorkspaceMutationTargetForAuthorizationFailure(
            MobileShellConnectionError.rpcError("unauthorized", "rejected"),
            target: rejectedTarget,
            client: rejectedClient,
            generation: rejectedGeneration
        )

        #expect(handled)
        #expect(store.remoteClient === replacementClient)
        #expect(store.connectionState == .connected)
        #expect(store.macConnectionStatus == .connected)
        #expect(!store.connectionRequiresReauth)
    }

    private enum SecondaryMutationAction {
        case close
        case reorder

        var method: String {
            switch self {
            case .close: "workspace.close"
            case .reorder: "workspace.move"
            }
        }
    }

    private struct SecondaryFixture {
        let store: MobileShellComposite
        let foregroundClient: MobileCoreRPCClient
        let secondaryWorkspaceID: MobileWorkspacePreview.ID
        let secondaryRouter: RoutingHostRouter
    }

    private func assertSecondaryAuthorizationFailure(
        action: SecondaryMutationAction
    ) async throws {
        let fixture = try await makeSecondaryFixture()
        let result: Result<Void, MobileWorkspaceMutationFailure>
        switch action {
        case .close:
            result = await fixture.store.closeWorkspace(id: fixture.secondaryWorkspaceID)
        case .reorder:
            result = await fixture.store.moveWorkspace(
                id: fixture.secondaryWorkspaceID,
                toGroup: nil,
                before: nil
            )
        }

        guard case let .failure(.authorizationFailed(hostDisplayName)) = result else {
            Issue.record("secondary authorization rejection should be reported: \(result)")
            return
        }
        #expect(hostDisplayName == "Secondary Mac")
        #expect(fixture.store.remoteClient === fixture.foregroundClient)
        #expect(fixture.store.connectionState == .connected)
        #expect(fixture.store.macConnectionStatus == .connected)
        #expect(!fixture.store.connectionRequiresReauth)
        #expect(fixture.store.secondaryMacSubscriptions["secondary-mac"] == nil)
        #expect(fixture.store.workspacesByMac["secondary-mac"]?.status == .unavailable)
        let recordedMethods = await fixture.secondaryRouter.recordedWorkspaceMutationMethods()
        #expect(!recordedMethods.isEmpty)
        #expect(recordedMethods.allSatisfy { $0 == action.method })
    }

    private func makeSecondaryFixture() async throws -> SecondaryFixture {
        let foregroundRouter = RoutingHostRouter()
        let secondaryRouter = RoutingHostRouter()
        await secondaryRouter.setWorkspaceMutationErrorCode("unauthorized")
        let capabilities = MobileWorkspaceActionCapabilities(
            supportsCloseActions: true,
            supportsMoveActions: true
        )
        let store = try await makeRoutingConnectedStore(
            router: foregroundRouter,
            connectionState: .connected,
            workspaceActionCapabilities: capabilities
        )
        let foregroundClient = try #require(store.remoteClient)
        try installSecondaryClient(
            on: store,
            macDeviceID: "secondary-mac",
            router: secondaryRouter,
            macScopedWorkspaceMutations: true
        )
        let sourceWorkspace = try #require(store.workspaces.first)
        var foregroundWorkspace = sourceWorkspace
        foregroundWorkspace.macDeviceID = "test-mac"
        foregroundWorkspace.macDisplayName = "Foreground Mac"
        foregroundWorkspace.name = "Foreground collision"
        var secondaryWorkspace = sourceWorkspace
        secondaryWorkspace.macDeviceID = "secondary-mac"
        secondaryWorkspace.macDisplayName = "Secondary Mac"
        secondaryWorkspace.name = "Secondary collision"
        store.setWorkspaceStatesForTesting(
            [
                "test-mac": MacWorkspaceState(
                    macDeviceID: "test-mac",
                    displayName: "Foreground Mac",
                    workspaces: [foregroundWorkspace],
                    status: .connected,
                    actionCapabilities: capabilities
                ),
                "secondary-mac": MacWorkspaceState(
                    macDeviceID: "secondary-mac",
                    displayName: "Secondary Mac",
                    workspaces: [secondaryWorkspace],
                    status: .connected,
                    actionCapabilities: capabilities
                ),
            ],
            foregroundMacDeviceID: "test-mac"
        )
        let secondaryWorkspaceID = try #require(
            store.workspaces.first(where: { $0.macDeviceID == "secondary-mac" })?.id
        )
        return SecondaryFixture(
            store: store,
            foregroundClient: foregroundClient,
            secondaryWorkspaceID: secondaryWorkspaceID,
            secondaryRouter: secondaryRouter
        )
    }
}
