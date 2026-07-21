import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileTaskComposerSubmitTests {
    @Test func submitTaskComposerSendsWorkspaceCreateSpec() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        let operationID = UUID()
        let spec = MobileWorkspaceCreateSpec(
            title: "Fix login",
            workingDirectory: "~/dev/cmux",
            initialCommand: "codex 'Fix login'",
            initialEnv: ["CMUX_TASK_PROMPT": "Fix login"],
            operationID: operationID
        )

        let result = await store.submitTaskComposer(macDeviceID: "test-mac", spec: spec)
        let records = await router.recordedWorkspaceCreates()

        guard case .success = result else {
            return #expect(Bool(false), "task composer create should succeed, got \(String(describing: result)); records \(records)")
        }
        #expect(records == [
            RoutingHostRouter.WorkspaceCreateRecord(
                groupID: nil,
                title: "Fix login",
                workingDirectory: "~/dev/cmux",
                initialCommand: "codex 'Fix login'",
                initialEnv: ["CMUX_TASK_PROMPT": "Fix login"],
                operationID: operationID.uuidString
            )
        ])
        let createdWorkspace = try #require(
            store.workspaces.first(where: { $0.name == "Created Workspace" })
        )
        #expect(store.selectedWorkspaceID == createdWorkspace.id)
        #expect(createdWorkspace.terminals.first?.isReady == true)
    }

    @Test func taskComposerRejectsResponseWithoutCreatedWorkspaceID() async throws {
        let router = RoutingHostRouter()
        await router.setWorkspaceCreateResponse(createdWorkspaceID: nil)
        let store = try await makeRoutingConnectedStore(router: router)
        let originalWorkspaceIDs = store.workspaces.map(\.id)
        let originalSelection = store.selectedWorkspaceID

        let result = await store.submitTaskComposer(
            macDeviceID: "test-mac",
            spec: MobileWorkspaceCreateSpec(title: "Task", operationID: UUID())
        )

        guard case let .failure(.rejected(hostDisplayName)) = result else {
            return #expect(Bool(false), "spec create must reject a response without created_workspace_id")
        }
        #expect(hostDisplayName == store.connectedHostName)
        #expect(store.workspaces.map(\.id) == originalWorkspaceIDs)
        #expect(store.selectedWorkspaceID == originalSelection)
    }

    @Test func specCreateRejectsBlankCreatedWorkspaceID() async throws {
        let router = RoutingHostRouter()
        await router.setWorkspaceCreateResponse(createdWorkspaceID: " \n\t ")
        let store = try await makeRoutingConnectedStore(router: router)
        let originalWorkspaceIDs = store.workspaces.map(\.id)
        let originalSelection = store.selectedWorkspaceID

        let result = await store.createWorkspaceRequest(
            spec: MobileWorkspaceCreateSpec(title: "Task", operationID: UUID())
        )

        guard case let .failure(.rejected(hostDisplayName)) = result else {
            return #expect(Bool(false), "spec create must reject a blank created_workspace_id")
        }
        #expect(hostDisplayName == store.connectedHostName)
        #expect(store.workspaces.map(\.id) == originalWorkspaceIDs)
        #expect(store.selectedWorkspaceID == originalSelection)
    }

    @Test func specCreateRejectsCreatedWorkspaceIDMissingFromReturnedList() async throws {
        let router = RoutingHostRouter()
        await router.setWorkspaceCreateResponse(
            createdWorkspaceID: "workspace-created",
            includesCreatedWorkspace: false
        )
        let store = try await makeRoutingConnectedStore(router: router)
        let originalWorkspaceIDs = store.workspaces.map(\.id)
        let originalSelection = store.selectedWorkspaceID

        let result = await store.createWorkspaceRequest(
            spec: MobileWorkspaceCreateSpec(title: "Task", operationID: UUID())
        )

        guard case let .failure(.rejected(hostDisplayName)) = result else {
            return #expect(Bool(false), "spec create must reject an ID absent from the returned workspace list")
        }
        #expect(hostDisplayName == store.connectedHostName)
        #expect(store.workspaces.map(\.id) == originalWorkspaceIDs)
        #expect(store.selectedWorkspaceID == originalSelection)
    }

    @Test func specLessCreateStillAcceptsResponseWithoutCreatedWorkspaceID() async throws {
        let router = RoutingHostRouter()
        await router.setWorkspaceCreateResponse(createdWorkspaceID: nil)
        let store = try await makeRoutingConnectedStore(router: router)

        let result = await store.createWorkspaceRequest()

        guard case .success = result else {
            return #expect(Bool(false), "ordinary workspace create must preserve legacy response compatibility")
        }
        #expect(await router.recordedWorkspaceCreateCount() == 1)
    }

    @Test func submitTaskComposerPreservesInitialCommandVerbatim() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        let initialCommand = " \nprintf '  preserved  '\n "

        let result = await store.submitTaskComposer(
            macDeviceID: "test-mac",
            spec: MobileWorkspaceCreateSpec(
                initialCommand: initialCommand,
                operationID: UUID()
            )
        )

        guard case .success = result else {
            return #expect(Bool(false), "task composer create should succeed")
        }
        #expect(await router.recordedWorkspaceCreates().map(\.initialCommand) == [initialCommand])
    }

    @Test func submitTaskComposerOmitsWhitespaceOnlyInitialCommand() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)

        let result = await store.submitTaskComposer(
            macDeviceID: "test-mac",
            spec: MobileWorkspaceCreateSpec(
                initialCommand: " \n\t ",
                operationID: UUID()
            )
        )

        guard case .success = result else {
            return #expect(Bool(false), "task composer create should succeed")
        }
        #expect(await router.recordedWorkspaceCreates().map(\.initialCommand) == [nil])
    }

    @Test func taskComposerFailsClosedBeforeCreateWhenForegroundMacLacksCapability() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router, hostCapabilities: [])

        let result = await store.submitTaskComposer(
            macDeviceID: "test-mac",
            spec: MobileWorkspaceCreateSpec(title: "Unsupported", operationID: UUID())
        )

        guard case .failure(.unsupported) = result else {
            return #expect(Bool(false), "old Mac should fail closed, got \(String(describing: result))")
        }
        #expect(await router.recordedWorkspaceCreateCount() == 0)
    }

    @Test func promotedSecondaryMacUsesItsOwnTaskCreateCapability() async throws {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["": [
                Self.pairedMac(macDeviceID: "secondary-old"),
                Self.pairedMac(macDeviceID: "secondary-current"),
            ]],
            blockedTeams: []
        )
        let unsupportedRouter = RoutingHostRouter()
        let unsupportedStore = try await makeRoutingConnectedStore(
            router: RoutingHostRouter(),
            pairedMacStore: pairedStore
        )
        try installSecondaryClient(
            on: unsupportedStore,
            macDeviceID: "secondary-old",
            router: unsupportedRouter,
            supportedHostCapabilities: []
        )

        let unsupported = await unsupportedStore.submitTaskComposer(
            macDeviceID: "secondary-old",
            spec: MobileWorkspaceCreateSpec(title: "Old Mac", operationID: UUID())
        )

        guard case .failure(.unsupported) = unsupported else {
            return #expect(Bool(false), "promoted old Mac should fail closed")
        }
        #expect(await unsupportedRouter.recordedWorkspaceCreateCount() == 0)

        let currentRouter = RoutingHostRouter()
        let currentStore = try await makeRoutingConnectedStore(
            router: RoutingHostRouter(),
            pairedMacStore: pairedStore
        )
        try installSecondaryClient(
            on: currentStore,
            macDeviceID: "secondary-current",
            router: currentRouter,
            supportedHostCapabilities: ["workspace.task_create.v1"]
        )

        let current = await currentStore.submitTaskComposer(
            macDeviceID: "secondary-current",
            spec: MobileWorkspaceCreateSpec(title: "Current Mac", operationID: UUID())
        )

        guard case .success = current else {
            return #expect(Bool(false), "promoted current Mac should create, got \(String(describing: current))")
        }
        #expect(await currentRouter.recordedWorkspaceCreateCount() == 1)
    }

    @Test func taskComposerDoesNotArmCreateBoundaryBeforeTargetCapabilityCheck() async throws {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["": [Self.pairedMac(macDeviceID: "secondary-old")]],
            blockedTeams: []
        )
        let store = try await makeRoutingConnectedStore(
            router: RoutingHostRouter(),
            pairedMacStore: pairedStore
        )
        let targetRouter = RoutingHostRouter()
        try installSecondaryClient(
            on: store,
            macDeviceID: "secondary-old",
            router: targetRouter,
            supportedHostCapabilities: []
        )
        var boundaryCallCount = 0

        let result = await store.submitTaskComposer(
            macDeviceID: "secondary-old",
            spec: MobileWorkspaceCreateSpec(title: "Unsupported", operationID: UUID()),
            willStartCreate: { boundaryCallCount += 1 }
        )

        guard case .failure(.unsupported) = result else {
            return #expect(Bool(false), "old Mac should fail before the create boundary")
        }
        #expect(boundaryCallCount == 0)
        #expect(await targetRouter.recordedWorkspaceCreateCount() == 0)
    }

    @Test func taskComposerArmsCreateBoundaryAfterTargetMacPromotion() async throws {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["": [Self.pairedMac(macDeviceID: "secondary-current")]],
            blockedTeams: []
        )
        let store = try await makeRoutingConnectedStore(
            router: RoutingHostRouter(),
            pairedMacStore: pairedStore
        )
        let targetRouter = RoutingHostRouter()
        try installSecondaryClient(
            on: store,
            macDeviceID: "secondary-current",
            router: targetRouter,
            supportedHostCapabilities: ["workspace.task_create.v1"]
        )
        var boundarySnapshots: [(macDeviceID: String?, workspaceIDs: Set<String>)] = []

        let result = await store.submitTaskComposer(
            macDeviceID: "secondary-current",
            spec: MobileWorkspaceCreateSpec(title: "Current", operationID: UUID()),
            willStartCreate: {
                boundarySnapshots.append((
                    macDeviceID: store.foregroundMacDeviceID,
                    workspaceIDs: Set(store.workspaces.map { $0.rpcWorkspaceID.rawValue })
                ))
            }
        )

        guard case .success = result else {
            return #expect(Bool(false), "current Mac should create after promotion")
        }
        #expect(boundarySnapshots.count == 1)
        #expect(boundarySnapshots.first?.macDeviceID == "secondary-current")
        #expect(boundarySnapshots.first?.workspaceIDs.contains(RoutingHostRouter.workspaceID) == true)
        #expect(await targetRouter.recordedWorkspaceCreateCount() == 1)
    }

    @Test func cancelledSubmissionDoesNotCrossCreateBoundary() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        var boundaryCallCount = 0

        let submission = Task { @MainActor in
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return await store.submitTaskComposer(
                macDeviceID: "test-mac",
                spec: MobileWorkspaceCreateSpec(title: "Cancelled", operationID: UUID()),
                willStartCreate: { boundaryCallCount += 1 }
            )
        }
        _ = await submission.value

        #expect(boundaryCallCount == 0)
        #expect(await router.recordedWorkspaceCreateCount() == 0)
    }

    @Test func pinnedContextRejectsAmbientReplacementClientAndGeneration() async throws {
        let targetRouter = RoutingHostRouter()
        let ambientRouter = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: targetRouter)
        let pinnedContext = try #require(store.captureWorkspaceCreateContext())

        #expect(pinnedContext.isCurrent(
            macDeviceID: store.foregroundMacDeviceID,
            client: store.remoteClient,
            generation: store.connectionGeneration
        ))

        store.bumpConnectionGenerationForTesting()
        try installFreshRemoteClient(on: store, router: ambientRouter)

        #expect(!pinnedContext.isCurrent(
            macDeviceID: store.foregroundMacDeviceID,
            client: store.remoteClient,
            generation: store.connectionGeneration
        ))
        #expect(await targetRouter.recordedWorkspaceCreateCount() == 0)
        #expect(await ambientRouter.recordedWorkspaceCreateCount() == 0)
    }

    @Test func pinnedContextKeepsTargetCapabilitySnapshot() async throws {
        let store = try await makeRoutingConnectedStore(
            router: RoutingHostRouter(),
            hostCapabilities: []
        )
        let pinnedContext = try #require(store.captureWorkspaceCreateContext())

        store.supportedHostCapabilities = ["workspace.task_create.v1"]

        #expect(!pinnedContext.supportedHostCapabilities.contains("workspace.task_create.v1"))
    }

    @Test func specLessCreateStillSendsOnlyGroupID() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router, macScopedWorkspaceMutations: true)

        let result = await store.createWorkspaceRequest(inGroup: "group-a")
        let records = await router.recordedWorkspaceCreates()

        guard case .success = result else {
            return #expect(Bool(false), "workspace create should succeed, got \(String(describing: result)); records \(records)")
        }
        #expect(records == [
            RoutingHostRouter.WorkspaceCreateRecord(
                groupID: "group-a",
                title: nil,
                workingDirectory: nil,
                initialCommand: nil,
                initialEnv: nil
            )
        ])
    }

    @Test func staleGenerationCreateFailureStillSurfacesFailure() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstWorkspaceCreate(true)
        await router.setRejectWorkspaceCreate(true)
        let store = try await makeRoutingConnectedStore(router: router)
        let spec = MobileWorkspaceCreateSpec(title: "Task")

        let create = Task { @MainActor in
            await store.createWorkspaceRequest(spec: spec)
        }
        await router.awaitFirstWorkspaceCreateReached()
        // The connection was replaced mid-flight (reconnect / Mac switch). The
        // rejected create must still report failure: mapping it to success lets
        // the composer dismiss and persist last-used defaults for a task that
        // was never created.
        store.connectionGeneration = UUID()
        await router.releaseFirstWorkspaceCreate()
        let result = await create.value

        guard case .failure = result else {
            return #expect(Bool(false), "stale rejected create should surface failure, got \(String(describing: result))")
        }
    }

    @Test func idempotentCreateRejectsStaleSuccessfulResponseSoCallerCanRetrySafely() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstWorkspaceCreate(true)
        let store = try await makeRoutingConnectedStore(router: router)
        let spec = MobileWorkspaceCreateSpec(title: "Task", operationID: UUID())

        let create = Task { @MainActor in
            await store.createWorkspaceRequest(spec: spec)
        }
        await router.awaitFirstWorkspaceCreateReached()
        store.connectionGeneration = UUID()
        await router.releaseFirstWorkspaceCreate()
        let result = await create.value

        guard case .failure(.notConnected) = result else {
            return #expect(Bool(false), "idempotent create should retry after a stale success")
        }
        #expect(await router.recordedWorkspaceCreateCount() == 1)
    }

    @Test func idempotentDecodedSuccessFailsClosedAfterCancellation() {
        let spec = MobileWorkspaceCreateSpec(title: "Task", operationID: UUID())

        let disposition = MobileShellComposite.WorkspaceCreatePinnedContext.postResponseDisposition(
            operationID: spec.operationID,
            isCancelled: true,
            isCurrent: true
        )

        #expect(disposition == .failClosed)
    }

    @Test func specCreateDoesNotCoalesceWithInFlightCreate() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstWorkspaceCreate(true)
        let store = try await makeRoutingConnectedStore(router: router)
        let spec = MobileWorkspaceCreateSpec(title: "Task")

        let firstCreate = Task { @MainActor in
            await store.createWorkspaceRequest(spec: spec)
        }
        await router.awaitFirstWorkspaceCreateReached()
        let secondResult = await store.createWorkspaceRequest(spec: spec)

        guard case .failure(.busy) = secondResult else {
            await router.releaseFirstWorkspaceCreate()
            _ = await firstCreate.value
            return #expect(Bool(false), "spec create should not coalesce with an in-flight create")
        }

        await router.releaseFirstWorkspaceCreate()
        _ = await firstCreate.value
        #expect(await router.recordedWorkspaceCreateCount() == 1)
    }

    @Test func invalidWorkingDirectoryMapsToSpecificComposerFailure() async throws {
        let router = RoutingHostRouter()
        await router.setWorkspaceCreateError(
            code: "invalid_working_directory",
            message: "The requested folder cannot be used for this task."
        )
        let store = try await makeRoutingConnectedStore(router: router)

        let result = await store.createWorkspaceRequest(
            spec: MobileWorkspaceCreateSpec(workingDirectory: "/missing")
        )

        guard case let .failure(.invalidWorkingDirectory(hostDisplayName)) = result else {
            return #expect(Bool(false), "working-directory rejection should map specifically")
        }
        #expect(hostDisplayName == store.connectedHostName)
    }

    @Test func tombstonePersistenceFailureMapsToSpecificComposerFailure() async throws {
        let router = RoutingHostRouter()
        await router.setWorkspaceCreateError(
            code: "persistence_failed",
            message: "Workspace task could not be reserved safely"
        )
        let store = try await makeRoutingConnectedStore(router: router)

        let result = await store.createWorkspaceRequest(
            spec: MobileWorkspaceCreateSpec(title: "Task", operationID: UUID())
        )

        guard case let .failure(.persistenceUnavailable(hostDisplayName)) = result else {
            return #expect(Bool(false), "persistence failure should map specifically")
        }
        #expect(hostDisplayName == store.connectedHostName)
    }

    @Test func completedOperationWithoutWorkspaceMapsToRecoveryFailure() async throws {
        let router = RoutingHostRouter()
        await router.setWorkspaceCreateError(
            code: "already_completed",
            message: "workspace.create operation already completed"
        )
        let store = try await makeRoutingConnectedStore(router: router)

        let result = await store.createWorkspaceRequest(
            spec: MobileWorkspaceCreateSpec(title: "Task", operationID: UUID())
        )

        guard case let .failure(.alreadyCompleted(hostDisplayName)) = result else {
            return #expect(Bool(false), "completed operation without a workspace needs recovery guidance")
        }
        #expect(hostDisplayName == store.connectedHostName)
    }

    @Test func unrelatedInvalidParamsRemainsGenericRejection() async throws {
        let router = RoutingHostRouter()
        await router.setWorkspaceCreateError(
            code: "invalid_params",
            message: "group_id is required for group placement"
        )
        let store = try await makeRoutingConnectedStore(router: router)

        let result = await store.createWorkspaceRequest(
            spec: MobileWorkspaceCreateSpec(title: "Rejected")
        )

        guard case let .failure(.rejected(hostDisplayName)) = result else {
            return #expect(Bool(false), "unrelated invalid_params should remain generic")
        }
        #expect(hostDisplayName == store.connectedHostName)
    }

    @Test func hostDirectoryValidationTimeoutMapsToRetryableTimeoutFailure() async throws {
        let router = RoutingHostRouter()
        await router.setWorkspaceCreateError(
            code: "request_timeout",
            message: "working_directory validation timed out"
        )
        let store = try await makeRoutingConnectedStore(router: router)

        let result = await store.createWorkspaceRequest(
            spec: MobileWorkspaceCreateSpec(workingDirectory: "/slow")
        )

        guard case let .failure(.requestTimedOut(hostDisplayName)) = result else {
            return #expect(Bool(false), "directory validation timeout should remain retryable")
        }
        #expect(hostDisplayName == store.connectedHostName)
    }

    @Test func hostDirectoryValidationOverloadMapsToBusyFailure() async throws {
        let router = RoutingHostRouter()
        await router.setWorkspaceCreateError(
            code: "busy",
            message: "working_directory validation is busy"
        )
        let store = try await makeRoutingConnectedStore(router: router)

        let result = await store.createWorkspaceRequest(
            spec: MobileWorkspaceCreateSpec(workingDirectory: "/queued")
        )

        guard case let .failure(.busy(hostDisplayName)) = result else {
            return #expect(Bool(false), "directory validation overload should remain retryable")
        }
        #expect(hostDisplayName == store.connectedHostName)
    }

    private static func pairedMac(macDeviceID: String) -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: macDeviceID,
            displayName: macDeviceID,
            routes: [],
            createdAt: Date(),
            lastSeenAt: Date(),
            isActive: false,
            stackUserID: "routing-user"
        )
    }
}
