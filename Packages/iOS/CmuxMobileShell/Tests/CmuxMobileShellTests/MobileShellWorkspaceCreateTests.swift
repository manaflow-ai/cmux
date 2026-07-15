import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
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

    @Test func timedWorkspaceReloadRejectsHierarchyFromAnOlderMutationEpoch() async throws {
        let router = RoutingHostRouter()
        await router.workspaceListGate.setHoldFirst(true)
        await router.workspaceListGate.setUsesOrdinalTitles(true)
        let store = try await makeRoutingConnectedStore(
            router: router,
            connectionState: .connected
        )

        let reload = Task { @MainActor in
            await store.reloadWorkspaceListFromMac(timeoutNanoseconds: 5_000_000_000)
        }
        await router.workspaceListGate.waitUntilFirstReached()
        store.advanceForegroundWorkspaceListMutationEpoch()
        await router.workspaceListGate.releaseFirst()
        let succeeded = await reload.value

        #expect(!succeeded)
        #expect(store.workspaces.first?.name == "Routing Workspace")
    }

    @Test func timedWorkspaceReloadPreservesFocusThatArrivesDuringTheRequest() async throws {
        let router = RoutingHostRouter()
        await router.workspaceListGate.setHoldFirst(true)
        let store = try await makeRoutingConnectedStore(
            router: router,
            connectionState: .connected
        )

        let reload = Task { @MainActor in
            await store.reloadWorkspaceListFromMac(timeoutNanoseconds: 5_000_000_000)
        }
        await router.workspaceListGate.waitUntilFirstReached()
        let focusEvent = try #require(MobileWorkspaceFocusEvent(payloadJSON: Data("""
        {"kind":"focus","workspace_id":"\(RoutingHostRouter.workspaceID)","focused_pane_id":null,"selected_terminal_id":"\(RoutingHostRouter.terminalB)"}
        """.utf8)))
        store.applyWorkspaceFocusEvent(focusEvent, macID: nil)
        #expect(store.selectedWorkspace?.selectedTerminalID?.rawValue == RoutingHostRouter.terminalB)
        await router.workspaceListGate.releaseFirst()

        #expect(await reload.value)
        #expect(store.selectedWorkspace?.selectedTerminalID?.rawValue == RoutingHostRouter.terminalB)
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

        #expect(await store.reloadWorkspaceListFromMac())
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

    @Test func delayedCreateCannotSelectWorkspaceMissingFromTrailingAuthoritativeList() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstWorkspaceCreate(true)
        let store = try await makeRoutingConnectedStore(
            router: router,
            connectionState: .connected
        )
        let liveWorkspaceID = try #require(store.workspaces.first?.id)
        let absentCreatedWorkspaceID = MobileWorkspacePreview.ID(rawValue: "workspace-created")

        let create = Task { @MainActor in
            await store.createWorkspaceRequest()
        }
        await router.awaitFirstWorkspaceCreateReached()

        #expect(await store.reloadWorkspaceListFromMac())
        #expect(store.workspaces.contains(where: {
            $0.rpcWorkspaceID == absentCreatedWorkspaceID
        }))
        #expect(store.selectedWorkspaceID == liveWorkspaceID)
        await router.setWorkspaceListIncludesCreatedWorkspace(false)

        await router.releaseFirstWorkspaceCreate()
        guard case .success = await create.value else {
            return #expect(Bool(false), "workspace create should remain acknowledged")
        }

        #expect(await router.workspaceListGate.requestCount() == 2)
        #expect(!store.workspaces.contains(where: {
            $0.rpcWorkspaceID == absentCreatedWorkspaceID
        }))
        #expect(store.selectedWorkspaceID == liveWorkspaceID)
        #expect(store.selectedWorkspaceID != absentCreatedWorkspaceID)
        #expect(store.workspaces.contains(where: { $0.id == store.selectedWorkspaceID }))
        let liveTerminalID = try #require(store.selectedTerminalID)
        #expect(
            store.shouldAutoFocusTerminalSurface(liveTerminalID.rawValue),
            "an absent created row must not suppress autofocus on the surviving live terminal"
        )
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
            _ = await store.createRemoteTerminal(in: workspaceID)
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

    @Test func delayedTerminalCreateCannotOverwriteNewerUserTerminalSelection() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstTerminalCreate(true)
        let store = try await makeRoutingConnectedStore(
            router: router,
            connectionState: .connected
        )
        let workspaceID = try #require(store.workspaces.first?.id)
        let originalTerminalID = MobileTerminalPreview.ID(rawValue: RoutingHostRouter.terminalA)
        let userSelectedTerminalID = MobileTerminalPreview.ID(rawValue: RoutingHostRouter.terminalB)
        store.setSelectedWorkspaceID(workspaceID)
        store.selectTerminal(originalTerminalID)

        let create = Task { @MainActor in
            await store.createRemoteTerminal(in: workspaceID)
        }
        await router.awaitFirstTerminalCreateReached()

        store.selectTerminal(userSelectedTerminalID)
        await router.releaseFirstTerminalCreate()

        guard case .success = await create.value else {
            Issue.record("Expected delayed terminal create to succeed")
            return
        }
        #expect(store.selectedWorkspaceID == workspaceID)
        #expect(store.selectedTerminalID == userSelectedTerminalID)
        #expect(store.workspaces.first?.terminals.contains(where: {
            $0.id.rawValue == "terminal-route-created"
        }) == true)
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
            _ = await store.createRemoteTerminal(in: workspaceID)
        }
        await router.awaitFirstTerminalCreateReached()
        _ = store.advanceForegroundWorkspaceListMutationEpoch()
        await router.releaseFirstTerminalCreate()
        await create.value

        #expect(await router.workspaceListGate.requestCount() == 1)
        #expect(store.terminalReorderGate.requiresRefresh(workspaceID: workspaceID))
        #expect(store.selectedTerminalID == originalTerminalID)
    }

    @Test func ambiguousTerminalCreateFailureReconcilesBeforeReleasingReservation() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstTerminalCreate(true)
        await router.setDropTerminalCreateResponse(true)
        let store = try await makeRoutingConnectedStore(
            router: router,
            connectionState: .connected,
            rpcRequestTimeoutNanoseconds: 10_000_000_000,
            subsequentRPCRequestTimeoutNanoseconds: 30_000_000_000,
            workspaceActionCapabilities: MobileWorkspaceActionCapabilities(
                supportsTerminalCloseActions: true,
                supportsTerminalCreateInPane: true,
                supportsTerminalReorderActions: true
            )
        )
        let workspace = try #require(store.workspaces.first)
        let originalTerminalID = store.selectedTerminalID
        let paneID = try #require(workspace.resolvedPanes.first?.id)
        let reservation = try #require(store.terminalReorderGate.reserve(
            workspaceID: workspace.id,
            paneID: paneID
        ))
        let owner = MobileTerminalCreationRequestOwner()

        var createResult: Result<Void, MobileWorkspaceMutationFailure>?
        #expect(owner.startIfIdle(
            claim: .reserved(reservation),
            gate: store.terminalReorderGate
        ) {
            createResult = await store.createRemoteTerminal(in: workspace.id)
        })
        await router.awaitFirstTerminalCreateReached()
        await router.releaseFirstTerminalCreate()
        await router.workspaceListGate.waitUntilRequestCount(1)
        for _ in 0..<300 where owner.isActive {
            try await Task.sleep(for: .milliseconds(1))
        }

        #expect(!owner.isActive)
        #expect(await router.recordedTerminalCreateCount() == 1)
        #expect(await router.workspaceListGate.requestCount() == 1)
        let refreshedWorkspace = store.workspaces.first(where: { $0.id == workspace.id })
        let createdTerminalIDs = refreshedWorkspace?.terminals.map(\.id.rawValue) ?? []
        #expect(createdTerminalIDs.contains("terminal-route-created"))
        #expect(store.selectedTerminalID == originalTerminalID)
        #expect(store.connectionError == nil)
        #expect(store.connectionErrorGuidance == nil)
        #expect(store.terminalReorderGate.canMutate(workspaceID: workspace.id))
        guard case .failure(.resultUnknownRefreshed) = createResult else {
            Issue.record("Expected reconciled unknown create result, got \(String(describing: createResult))")
            return
        }
    }

    @Test func ambiguousTerminalCreateFailureKeepsGateClosedWhenReconciliationFails() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstTerminalCreate(true)
        await router.setDropTerminalCreateResponse(true)
        await router.setRejectWorkspaceList(true)
        let store = try await makeRoutingConnectedStore(
            router: router,
            connectionState: .connected,
            rpcRequestTimeoutNanoseconds: 10_000_000_000,
            subsequentRPCRequestTimeoutNanoseconds: 30_000_000_000,
            workspaceActionCapabilities: MobileWorkspaceActionCapabilities(
                supportsTerminalCloseActions: true,
                supportsTerminalCreateInPane: true,
                supportsTerminalReorderActions: true
            )
        )
        let workspace = try #require(store.workspaces.first)
        let paneID = try #require(workspace.resolvedPanes.first?.id)
        let reservation = try #require(store.terminalReorderGate.reserve(
            workspaceID: workspace.id,
            paneID: paneID
        ))
        let owner = MobileTerminalCreationRequestOwner()

        #expect(owner.startIfIdle(
            claim: .reserved(reservation),
            gate: store.terminalReorderGate
        ) {
            _ = await store.createRemoteTerminal(in: workspace.id)
        })
        await router.awaitFirstTerminalCreateReached()
        await router.releaseFirstTerminalCreate()
        await router.workspaceListGate.waitUntilRequestCount(1)
        for _ in 0..<300 where owner.isActive {
            try await Task.sleep(for: .milliseconds(1))
        }

        #expect(!owner.isActive)
        #expect(await router.recordedTerminalCreateCount() == 1)
        #expect(await router.workspaceListGate.requestCount() == 1)
        #expect(store.terminalReorderGate.requiresRefresh(workspaceID: workspace.id))
        #expect(!store.terminalReorderGate.canMutate(workspaceID: workspace.id))
    }

    @Test func newTerminalActionRecoversRefreshRequiredHierarchy() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: router,
            connectionState: .connected,
            workspaceActionCapabilities: MobileWorkspaceActionCapabilities(
                supportsTerminalCloseActions: true,
                supportsTerminalCreateInPane: true,
                supportsTerminalReorderActions: true
            )
        )
        let workspaceID = try #require(store.workspaces.first?.id)
        store.terminalReorderGate.requireRefresh(workspaceID: workspaceID)

        store.createTerminal(in: workspaceID)
        for _ in 0..<300 where store.terminalReorderGate.requiresRefresh(workspaceID: workspaceID) {
            try await Task.sleep(for: .milliseconds(1))
        }

        #expect(await router.workspaceListGate.requestCount() == 1)
        #expect(await router.recordedTerminalCreateCount() == 0)
        #expect(!store.terminalReorderGate.requiresRefresh(workspaceID: workspaceID))
        #expect(store.terminalReorderGate.canMutate(workspaceID: workspaceID))
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
