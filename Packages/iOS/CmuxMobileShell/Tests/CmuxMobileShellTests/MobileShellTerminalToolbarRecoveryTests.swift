import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellTerminalToolbarRecoveryTests {
    @Test func disconnectedCreateCompletesUnknownExactlyOnceAndFencesHierarchy() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstTerminalCreate(true)
        let store = try await makeRecoveryStore(router: router)
        let workspace = try #require(store.workspaces.first)
        let paneID = try #require(workspace.resolvedPanes.first?.id)
        var completions: [Result<Void, MobileWorkspaceMutationFailure>] = []

        store.createTerminal(in: workspace.id, paneID: paneID) { result in
            completions.append(result)
        }
        await router.awaitFirstTerminalCreateReached()

        #expect(store.terminalCreationRequestOwner.isActive)
        #expect(store.terminalReorderGate.isActive(workspaceID: workspace.id))

        store.clearRemoteConnectionContext()

        #expect(!store.terminalCreationRequestOwner.isActive)
        #expect(completions.count == 1)
        guard completions.count == 1 else {
            await router.releaseFirstTerminalCreate()
            return
        }
        guard case .failure(.resultUnknownNeedsRefresh) = completions[0] else {
            await router.releaseFirstTerminalCreate()
            Issue.record("cancelled in-flight create should report an unknown result: \(completions[0])")
            return
        }
        #expect(store.terminalReorderGate.requiresRefresh(workspaceID: workspace.id))
        #expect(!store.terminalReorderGate.canMutate(workspaceID: workspace.id))

        await router.releaseFirstTerminalCreate()
        for _ in 0..<100 {
            await Task.yield()
        }

        #expect(await router.recordedTerminalCreateCount() == 1)
        #expect(completions.count == 1, "the late transport response must not complete the toolbar a second time")
    }

    @Test func toolbarCompletionWaitsForSuccessfulHierarchyRecovery() async throws {
        let router = RoutingHostRouter()
        await router.workspaceListGate.setHoldFirst(true)
        let store = try await makeRecoveryStore(router: router)
        let workspaceID = try #require(store.workspaces.first?.id)
        store.terminalReorderGate.requireRefresh(workspaceID: workspaceID)
        var completions: [Result<Void, MobileWorkspaceMutationFailure>] = []

        store.createTerminal(in: workspaceID) { result in
            completions.append(result)
        }
        await router.workspaceListGate.waitUntilFirstReached()

        #expect(completions.isEmpty, "toolbar completion must remain pending while recovery is in flight")

        await router.workspaceListGate.releaseFirst()
        try await waitForTerminalCreationOwnerToFinish(store)

        #expect(completions.count == 1)
        guard completions.count == 1 else { return }
        guard case .success = completions[0] else {
            Issue.record("successful hierarchy recovery should complete with success: \(completions[0])")
            return
        }
        #expect(!store.terminalReorderGate.requiresRefresh(workspaceID: workspaceID))
    }

    @Test func toolbarCompletionReportsHierarchyRecoveryTimeout() async throws {
        let router = RoutingHostRouter()
        await router.workspaceListGate.setHoldFirst(true)
        let store = try await makeRecoveryStore(
            router: router,
            rpcRequestTimeoutNanoseconds: 20_000_000
        )
        let workspaceID = try #require(store.workspaces.first?.id)
        store.terminalReorderGate.requireRefresh(workspaceID: workspaceID)
        var completions: [Result<Void, MobileWorkspaceMutationFailure>] = []

        store.createTerminal(in: workspaceID) { result in
            completions.append(result)
        }
        await router.workspaceListGate.waitUntilFirstReached()

        #expect(completions.isEmpty, "toolbar completion must remain pending while recovery is in flight")
        try await waitForTerminalCreationOwnerToFinish(store)
        await router.workspaceListGate.releaseFirst()

        #expect(completions.count == 1)
        guard completions.count == 1 else { return }
        guard case .failure(.appliedNeedsRefresh) = completions[0] else {
            Issue.record("timed-out hierarchy recovery should report appliedNeedsRefresh: \(completions[0])")
            return
        }
        #expect(store.terminalReorderGate.requiresRefresh(workspaceID: workspaceID))
    }

    private func makeRecoveryStore(
        router: RoutingHostRouter,
        rpcRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000
    ) async throws -> MobileShellComposite {
        try await makeRoutingConnectedStore(
            router: router,
            connectionState: .connected,
            rpcRequestTimeoutNanoseconds: rpcRequestTimeoutNanoseconds,
            workspaceActionCapabilities: MobileWorkspaceActionCapabilities(
                supportsTerminalCloseActions: true,
                supportsTerminalCreateInPane: true,
                supportsTerminalReorderActions: true
            )
        )
    }

    private func waitForTerminalCreationOwnerToFinish(
        _ store: MobileShellComposite
    ) async throws {
        for _ in 0..<300 where store.terminalCreationRequestOwner.isActive {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(!store.terminalCreationRequestOwner.isActive)
    }
}
