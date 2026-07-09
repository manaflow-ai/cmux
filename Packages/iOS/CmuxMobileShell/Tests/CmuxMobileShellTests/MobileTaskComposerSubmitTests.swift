import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileTaskComposerSubmitTests {
    @Test func submitTaskComposerSendsWorkspaceCreateSpec() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        let spec = MobileWorkspaceCreateSpec(
            title: "Fix login",
            workingDirectory: "~/dev/cmux",
            initialCommand: "codex 'Fix login'",
            initialEnv: ["CMUX_TASK_PROMPT": "Fix login"]
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
                initialEnv: ["CMUX_TASK_PROMPT": "Fix login"]
            )
        ])
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
