import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellWorkspaceCreateTests {
    @Test func terminalCreateHoldFixtureOnlyGatesFirstRequest() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstTerminalCreate(true)
        let firstInfo = RoutingHostRouter.RequestInfo(
            method: "terminal.create",
            id: "first",
            workspaceID: RoutingHostRouter.workspaceID
        )
        let secondInfo = RoutingHostRouter.RequestInfo(
            method: "terminal.create",
            id: "second",
            workspaceID: RoutingHostRouter.workspaceID
        )

        let first = Task { await router.response(firstInfo) }
        await router.awaitFirstTerminalCreateReached()
        let second = Task { await router.response(secondInfo) }
        for _ in 0..<100 where await router.recordedTerminalCreateCount() < 2 {
            try await Task.sleep(for: .milliseconds(1))
        }

        let requestCount = await router.recordedTerminalCreateCount()
        #expect(requestCount == 2)
        guard requestCount == 2 else {
            await router.releaseFirstTerminalCreate()
            first.cancel()
            second.cancel()
            _ = await first.value
            _ = await second.value
            return
        }
        let heldCount = await router.recordedHeldTerminalCreateCount()
        await router.releaseFirstTerminalCreate()
        await router.releaseFirstTerminalCreate()
        _ = await first.value
        _ = await second.value

        #expect(heldCount == 1)
    }

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

    @Test func createWorkspaceRequestFailureDoesNotSetGlobalConnectionError() async throws {
        let router = RoutingHostRouter()
        await router.setRejectWorkspaceCreate(true)
        let store = try await makeRoutingConnectedStore(router: router)

        let result = await store.createWorkspaceRequest()

        guard case .failure(.rejected) = result else {
            return #expect(Bool(false), "request create should return the host rejection")
        }
        #expect(store.connectionError == nil)
        #expect(store.connectionErrorGuidance == nil)
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

    @Test func staleCreateResponseRequiresAuthoritativeReconciliation() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstWorkspaceCreate(true)
        let store = try await makeRoutingConnectedStore(
            router: router,
            connectionState: .connected
        )

        let create = Task { @MainActor in
            await store.createWorkspaceRequest()
        }
        await router.awaitFirstWorkspaceCreateReached()
        let laterMutationEpoch = store.advanceForegroundWorkspaceListMutationEpoch()

        await router.releaseFirstWorkspaceCreate()
        let createResult = await create.value
        guard case .success = createResult else {
            return #expect(Bool(false), "workspace create should succeed: \(createResult)")
        }

        #expect(await router.workspaceListGate.requestCount() == 1)
        #expect(store.foregroundWorkspaceListAppliedMutationEpoch >= laterMutationEpoch)
    }

    @Test func staleCreateResponseReconcilesWithoutOverwritingNewerAuthoritativeHierarchy() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstWorkspaceCreate(true)
        await router.workspaceListGate.setUsesOrdinalTitles(true)
        let store = try await makeRoutingConnectedStore(
            router: router,
            connectionState: .connected
        )

        let create = Task { @MainActor in
            await store.createWorkspaceRequest()
        }
        await router.awaitFirstWorkspaceCreateReached()

        #expect(await store.refreshForegroundWorkspaceListAfterMutation())
        #expect(store.workspaces.first(where: { $0.rpcWorkspaceID.rawValue == RoutingHostRouter.workspaceID })?.name == "Stale Workspace")

        await router.releaseFirstWorkspaceCreate()
        let createResult = await create.value
        guard case .success = createResult else {
            return #expect(Bool(false), "workspace create should succeed: \(createResult)")
        }

        #expect(await router.workspaceListGate.requestCount() == 2)
        #expect(store.workspaces.first(where: { $0.rpcWorkspaceID.rawValue == RoutingHostRouter.workspaceID })?.name == "Fresh Workspace")
        #expect(store.workspaces.contains(where: { $0.rpcWorkspaceID.rawValue == "workspace-created" }))
        #expect(store.selectedWorkspace?.rpcWorkspaceID.rawValue == "workspace-created")
        #expect(store.selectedTerminalID?.rawValue == "terminal-created")
    }

    @Test func olderWorkspaceCreateResponseCannotOverwriteNewerTerminalCreate() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstWorkspaceCreate(true)
        await router.setHoldFirstTerminalCreate(true)
        await router.workspaceListGate.setUsesOrdinalTitles(true)
        let store = try await makeRoutingConnectedStore(
            router: router,
            connectionState: .connected
        )
        let workspaceID = try #require(store.workspaces.first?.id)

        let workspaceCreate = Task { @MainActor in
            await store.createWorkspaceRequest()
        }
        await router.awaitFirstWorkspaceCreateReached()
        let terminalCreate = Task { @MainActor in
            await store.createRemoteTerminal(in: workspaceID)
        }
        await router.awaitFirstTerminalCreateReached()

        await router.releaseFirstTerminalCreate()
        await terminalCreate.value
        #expect(store.selectedWorkspaceID == workspaceID)
        #expect(store.selectedTerminalID?.rawValue == "terminal-route-created")

        await router.releaseFirstWorkspaceCreate()
        let workspaceResult = await workspaceCreate.value
        guard case .success = workspaceResult else {
            return #expect(Bool(false), "workspace create should succeed: \(workspaceResult)")
        }

        #expect(await router.workspaceListGate.requestCount() == 1)
        #expect(store.workspaces.first(where: { $0.id == workspaceID })?.name == "Stale Workspace")
        #expect(store.workspaces.first(where: { $0.id == workspaceID })?.terminals.contains(where: {
            $0.id.rawValue == "terminal-route-created"
        }) == true)
        #expect(store.workspaces.contains(where: { $0.rpcWorkspaceID.rawValue == "workspace-created" }))
        #expect(store.selectedWorkspaceID == workspaceID)
        #expect(store.selectedTerminalID?.rawValue == "terminal-route-created")
    }

    @Test func acknowledgedWorkspaceCreateReportsFailedAuthoritativeReconciliation() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstWorkspaceCreate(true)
        await router.setRejectWorkspaceList(true)
        let store = try await makeRoutingConnectedStore(
            router: router,
            connectionState: .connected
        )

        let create = Task { @MainActor in
            await store.createWorkspaceRequest()
        }
        await router.awaitFirstWorkspaceCreateReached()
        _ = store.advanceForegroundWorkspaceListMutationEpoch()
        await router.releaseFirstWorkspaceCreate()

        let result = await create.value
        guard case .failure(.appliedNeedsRefresh) = result else {
            return #expect(Bool(false), "acknowledged create with failed refresh must require refresh: \(result)")
        }
        #expect(await router.workspaceListGate.requestCount() == 1)
        #expect(!store.workspaces.contains(where: { $0.rpcWorkspaceID.rawValue == "workspace-created" }))
    }

    @Test func acknowledgedTerminalCreateRetainsHierarchyRefreshRequirement() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstTerminalCreate(true)
        await router.setRejectWorkspaceList(true)
        let store = try await makeRoutingConnectedStore(
            router: router,
            connectionState: .connected
        )
        let workspaceID = try #require(store.workspaces.first?.id)
        let originalTerminalID = store.selectedTerminalID

        let create = Task { @MainActor in
            await store.createRemoteTerminal(in: workspaceID)
        }
        await router.awaitFirstTerminalCreateReached()
        _ = store.advanceForegroundWorkspaceListMutationEpoch()
        await router.releaseFirstTerminalCreate()
        await create.value

        #expect(await router.workspaceListGate.requestCount() == 1)
        #expect(store.terminalReorderGate.requiresRefresh(workspaceID: workspaceID))
        #expect(store.selectedTerminalID == originalTerminalID)
    }

    @Test func invalidatedWorkspaceCreateCompletionRemainsBenign() async throws {
        let originalRouter = RoutingHostRouter()
        await originalRouter.setHoldFirstWorkspaceCreate(true)
        let store = try await makeRoutingConnectedStore(
            router: originalRouter,
            connectionState: .connected
        )
        let replacementRouter = RoutingHostRouter()

        let create = Task { @MainActor in
            await store.createWorkspaceRequest()
        }
        await originalRouter.awaitFirstWorkspaceCreateReached()
        try installFreshRemoteClient(on: store, router: replacementRouter)
        await originalRouter.releaseFirstWorkspaceCreate()

        let result = await create.value
        guard case .success = result else {
            return #expect(Bool(false), "completion from a replaced client should be ignored: \(result)")
        }
        #expect(await originalRouter.workspaceListGate.requestCount() == 0)
        #expect(await replacementRouter.workspaceListGate.requestCount() == 0)
        #expect(!store.workspaces.contains(where: { $0.rpcWorkspaceID.rawValue == "workspace-created" }))
    }
}
