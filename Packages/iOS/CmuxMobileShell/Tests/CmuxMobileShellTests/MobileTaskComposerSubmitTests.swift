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
        let pairedStore = DelayedTeamPairedMacStore(recordsByTeam: [:], blockedTeams: [])
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

    @Test func connectionDrivenCancellationNeverReportsCreateSuccess() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstWorkspaceCreate(true)
        let store = try await makeRoutingConnectedStore(router: router)

        let create = Task { @MainActor in
            await store.createWorkspaceRequest(spec: MobileWorkspaceCreateSpec(title: "Task"))
        }
        await router.awaitFirstWorkspaceCreateReached()
        store.signOut()
        await router.releaseFirstWorkspaceCreate()
        let result = await create.value

        guard case .failure = result else {
            return #expect(Bool(false), "a connection-cancelled create must never report success")
        }
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
}
