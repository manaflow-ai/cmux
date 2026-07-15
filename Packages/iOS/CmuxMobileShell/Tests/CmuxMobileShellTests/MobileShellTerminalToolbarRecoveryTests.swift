import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellTerminalToolbarRecoveryTests {
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
