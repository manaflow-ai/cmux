import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellWorkspaceCreateTests {
    @Test func createWorkspaceInGroupWithoutConnectionReturnsNotConnected() {
        let store = MobileShellComposite.preview()
        let initialWorkspaceIDs = store.workspaces.map(\.id)

        let result = store.createWorkspace(inGroup: "group-offline")

        guard case .failure(.notConnected) = result else {
            return #expect(Bool(false), "offline group create should return a notConnected failure")
        }
        #expect(store.workspaces.map(\.id) == initialWorkspaceIDs)
    }

    @Test func duplicateCreateWorkspaceRequestAwaitsInFlightResult() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstWorkspaceCreate(true)
        await router.setRejectWorkspaceCreate(true)
        let store = try await makeRoutingConnectedStore(router: router)

        let firstCreate = Task { @MainActor in
            await store.createWorkspaceRequest()
        }
        await router.awaitFirstWorkspaceCreateReached()
        let secondCreate = Task { @MainActor in
            await store.createWorkspaceRequest()
        }

        await router.releaseFirstWorkspaceCreate()
        let firstResult = await firstCreate.value
        let secondResult = await secondCreate.value

        guard case .failure(.rejected) = firstResult else {
            return #expect(Bool(false), "first create should report the host rejection")
        }
        guard case .failure(.rejected) = secondResult else {
            return #expect(Bool(false), "duplicate create should reuse the in-flight rejection")
        }
        #expect(await router.recordedWorkspaceCreateCount() == 1)
    }
}
