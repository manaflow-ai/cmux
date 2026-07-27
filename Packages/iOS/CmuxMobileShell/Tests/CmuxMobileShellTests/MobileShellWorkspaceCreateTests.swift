import CmuxMobileRPC
import Foundation
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

    @Test func specLessCreateReturnsSuccessWhenConnectionChangesAfterHostCreatedWorkspace() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstWorkspaceCreate(true)
        let store = try await makeRoutingConnectedStore(router: router)

        let create = Task { @MainActor in
            await store.createWorkspaceRequest()
        }
        await router.awaitFirstWorkspaceCreateReached()
        store.connectionGeneration = UUID()
        await router.releaseFirstWorkspaceCreate()
        let result = await create.value

        guard case .success = result else {
            return #expect(Bool(false), "accepted legacy create must not invite a duplicate retry")
        }
        #expect(await router.recordedWorkspaceCreateCount() == 1)
    }

    @Test func nonIdempotentSpecCreateReturnsSuccessAfterHostCreatedWorkspace() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstWorkspaceCreate(true)
        let store = try await makeRoutingConnectedStore(router: router)

        let create = Task { @MainActor in
            await store.createWorkspaceRequest(spec: MobileWorkspaceCreateSpec(title: "Legacy titled create"))
        }
        await router.awaitFirstWorkspaceCreateReached()
        store.connectionGeneration = UUID()
        await router.releaseFirstWorkspaceCreate()
        let result = await create.value

        guard case .success = result else {
            return #expect(Bool(false), "accepted non-idempotent create must not invite a duplicate retry")
        }
        #expect(await router.recordedWorkspaceCreateCount() == 1)
    }

    @Test func specLessDecodedSuccessSurvivesCancellation() {
        let spec: MobileWorkspaceCreateSpec? = nil

        let disposition = MobileShellComposite.WorkspaceCreatePinnedContext.postResponseDisposition(
            operationID: spec?.operationID,
            isCancelled: true,
            isCurrent: true
        )

        #expect(disposition == .preserveSuccess)
    }

    @Test func nonIdempotentSpecDecodedSuccessSurvivesCancellation() {
        let spec = MobileWorkspaceCreateSpec(title: "Legacy titled create")

        let disposition = MobileShellComposite.WorkspaceCreatePinnedContext.postResponseDisposition(
            operationID: spec.operationID,
            isCancelled: true,
            isCurrent: true
        )

        #expect(disposition == .preserveSuccess)
    }

    @Test func specLessCreateCancellationAfterSendDoesNotInviteDuplicateRetry() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstWorkspaceCreate(true)
        let store = try await makeRoutingConnectedStore(router: router)

        let create = Task { @MainActor in
            await store.createWorkspaceRequest()
        }
        await router.awaitFirstWorkspaceCreateReached()
        store.cancelRemoteOperationTasks()
        await router.releaseFirstWorkspaceCreate()
        let result = await create.value

        guard case .success = result else {
            return #expect(Bool(false), "ambiguous legacy create must not invite a duplicate retry")
        }
        #expect(await router.recordedWorkspaceCreateCount() == 1)
    }

    @Test func specLessCreateCancellationRacingHostRejectionStillSurfacesFailure() async {
        let disposition = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(Task.isCancelled)
            return MobileShellComposite.WorkspaceCreatePinnedContext.caughtErrorDisposition(
                operationID: nil,
                error: MobileWorkspaceMutationFailure.rejected(hostDisplayName: "Test Mac")
            )
        }.value

        #expect(disposition == .surfaceError)
    }

    @Test func ambiguousLegacyTransportFailuresPreserveAtMostOnceSuccess() {
        for error in [
            MobileShellConnectionError.connectionClosed,
            MobileShellConnectionError.requestTimedOut,
            MobileShellConnectionError.invalidResponse,
        ] {
            #expect(
                MobileShellComposite.WorkspaceCreatePinnedContext.caughtErrorDisposition(
                    operationID: nil,
                    error: error
                ) == .preserveSuccess
            )
            #expect(
                MobileShellComposite.WorkspaceCreatePinnedContext.caughtErrorDisposition(
                    operationID: UUID(),
                    error: error
                ) == .failClosed
            )
        }
    }

    @Test func definiteLegacyHostFailureStillSurfaces() {
        #expect(
            MobileShellComposite.WorkspaceCreatePinnedContext.caughtErrorDisposition(
                operationID: nil,
                error: MobileShellConnectionError.rpcError("rejected", "Host rejected create")
            ) == .surfaceError
        )
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
