import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellWorkspaceCreateTests {
    @Test func createWorkspaceInGroupWithoutConnectionDoesNotCreateLocalWorkspace() {
        let store = MobileShellComposite.preview()
        let initialWorkspaceIDs = store.workspaces.map(\.id)

        store.createWorkspace(inGroup: "group-offline")

        #expect(store.workspaces.map(\.id) == initialWorkspaceIDs)
    }

    @Test func createWorkspaceRequestWithoutConnectionDoesNotCreateLocalWorkspace() async {
        let store = MobileShellComposite.preview()
        let initialWorkspaceIDs = store.workspaces.map(\.id)

        let result = await store.createWorkspaceRequest()

        guard case .failure(.notConnected) = result else {
            return #expect(Bool(false), "disconnected request create should surface notConnected")
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

    @Test func differentGroupCreateWorkspaceRequestDoesNotJoinInFlightResult() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstWorkspaceCreate(true)
        await router.setRejectWorkspaceCreate(true)
        let store = try await makeRoutingConnectedStore(router: router, macScopedWorkspaceMutations: true)

        let firstCreate = Task { @MainActor in
            await store.createWorkspaceRequest(inGroup: "group-a")
        }
        await router.awaitFirstWorkspaceCreateReached()
        let secondResult = await store.createWorkspaceRequest(inGroup: "group-b")

        guard case .failure(.busy) = secondResult else {
            await router.releaseFirstWorkspaceCreate()
            _ = await firstCreate.value
            return #expect(Bool(false), "different group create should not reuse an in-flight request")
        }

        await router.releaseFirstWorkspaceCreate()
        let firstResult = await firstCreate.value
        guard case .failure(.rejected) = firstResult else {
            return #expect(Bool(false), "first create should still report its own host result")
        }
        #expect(await router.recordedWorkspaceCreateCount() == 1)
        #expect(await router.recordedWorkspaceCreateGroupIDs() == ["group-a"])
    }
}
