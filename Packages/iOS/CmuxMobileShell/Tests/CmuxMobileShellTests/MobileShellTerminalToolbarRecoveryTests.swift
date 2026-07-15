import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
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

    @Test func replacementCancelledCompatibilityCreateFencesHierarchyBeforeRetry() async throws {
        let originalRouter = RoutingHostRouter()
        await originalRouter.setHoldFirstTerminalCreate(true)
        let compatibilityCapabilities = MobileWorkspaceActionCapabilities(
            supportsTerminalCloseActions: false,
            supportsTerminalCreateInPane: true,
            supportsTerminalReorderActions: false
        )
        let store = try await makeRoutingConnectedStore(
            router: originalRouter,
            connectionState: .connected,
            workspaceActionCapabilities: compatibilityCapabilities
        )
        let workspace = try #require(store.workspaces.first)
        var firstCompletions: [Result<Void, MobileWorkspaceMutationFailure>] = []

        store.createTerminal(in: workspace.id) { result in
            firstCompletions.append(result)
        }
        await originalRouter.awaitFirstTerminalCreateReached()

        #expect(store.terminalCreationRequestOwner.isActive)
        #expect(!store.terminalReorderGate.isActive(workspaceID: workspace.id))

        store.clearRemoteConnectionContext(preservingOtherMacWorkspaceState: true)
        let replacementRouter = RoutingHostRouter()
        try installFreshRemoteClient(on: store, router: replacementRouter)
        store.foregroundMacDeviceID = workspace.macDeviceID

        #expect(!store.terminalCreationRequestOwner.isActive)
        #expect(firstCompletions.count == 1)
        guard firstCompletions.count == 1 else {
            await originalRouter.releaseFirstTerminalCreate()
            return
        }
        guard case .failure(.resultUnknownNeedsRefresh) = firstCompletions[0] else {
            await originalRouter.releaseFirstTerminalCreate()
            Issue.record(
                "cancelled compatibility create should report an unknown result: \(firstCompletions[0])"
            )
            return
        }
        #expect(store.terminalReorderGate.requiresRefresh(workspaceID: workspace.id))
        #expect(!store.terminalReorderGate.canMutate(workspaceID: workspace.id))

        let retryResult = await withCheckedContinuation { continuation in
            store.createTerminal(in: workspace.id) { result in
                continuation.resume(returning: result)
            }
        }

        guard case .success = retryResult else {
            await originalRouter.releaseFirstTerminalCreate()
            Issue.record("retry should recover the uncertain hierarchy: \(retryResult)")
            return
        }
        #expect(await replacementRouter.workspaceListGate.requestCount() == 1)
        let originalCreateCount = await originalRouter.recordedTerminalCreateCount()
        let replacementCreateCount = await replacementRouter.recordedTerminalCreateCount()
        let totalCreateCount = originalCreateCount + replacementCreateCount
        #expect(totalCreateCount == 1)
        #expect(!store.terminalReorderGate.requiresRefresh(workspaceID: workspace.id))
        #expect(store.terminalReorderGate.canMutate(workspaceID: workspace.id))

        await originalRouter.releaseFirstTerminalCreate()
        for _ in 0..<100 {
            await Task.yield()
        }
        #expect(firstCompletions.count == 1)
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

    @Test func secondaryToolbarRecoveryRetainsCapturedOwnerAcrossForegroundRescope() async throws {
        let foregroundRouter = RoutingHostRouter()
        let secondaryRouter = RoutingHostRouter()
        await secondaryRouter.workspaceListGate.setHoldFirst(true)
        let fixture = try await makeSecondaryRecoveryStore(
            foregroundRouter: foregroundRouter,
            secondaryRouter: secondaryRouter
        )
        var completions: [Result<Void, MobileWorkspaceMutationFailure>] = []

        fixture.store.createTerminal(in: fixture.secondaryWorkspaceID) { result in
            completions.append(result)
        }
        try rescopeToReplacementForeground(fixture, router: foregroundRouter)
        try await waitForRecoveryRoute(
            store: fixture.store,
            capturedOwner: secondaryRouter,
            currentForeground: foregroundRouter
        )

        let capturedOwnerRequests = await secondaryRouter.workspaceListGate.requestCount()
        let currentForegroundRequests = await foregroundRouter.workspaceListGate.requestCount()
        #expect(capturedOwnerRequests == 1)
        #expect(currentForegroundRequests == 0)
        #expect(completions.isEmpty, "completion must wait for the captured owner's response")
        #expect(fixture.store.terminalCreationRequestOwner.isActive)
        #expect(fixture.store.terminalReorderGate.isActive(
            workspaceID: fixture.secondaryWorkspaceID
        ))
        #expect(fixture.store.terminalReorderGate.requiresRefresh(
            workspaceID: fixture.secondaryWorkspaceID
        ))
        guard capturedOwnerRequests == 1, currentForegroundRequests == 0 else { return }

        await secondaryRouter.workspaceListGate.releaseFirst()
        try await waitForTerminalCreationOwnerToFinish(fixture.store)

        #expect(completions.count == 1)
        guard completions.count == 1 else { return }
        guard case .success = completions[0] else {
            Issue.record("captured owner recovery should succeed: \(completions[0])")
            return
        }
        #expect(!fixture.store.terminalReorderGate.requiresRefresh(
            workspaceID: fixture.secondaryWorkspaceID
        ))
        #expect(fixture.store.terminalReorderGate.canMutate(
            workspaceID: fixture.secondaryWorkspaceID
        ))
    }

    @Test func secondaryToolbarRecoveryFailureUsesCapturedHostAcrossForegroundRescope() async throws {
        let foregroundRouter = RoutingHostRouter()
        let secondaryRouter = RoutingHostRouter()
        await foregroundRouter.setRejectWorkspaceList(true)
        await secondaryRouter.setRejectWorkspaceList(true)
        await secondaryRouter.workspaceListGate.setHoldFirst(true)
        let fixture = try await makeSecondaryRecoveryStore(
            foregroundRouter: foregroundRouter,
            secondaryRouter: secondaryRouter
        )
        var completions: [Result<Void, MobileWorkspaceMutationFailure>] = []

        fixture.store.createTerminal(in: fixture.secondaryWorkspaceID) { result in
            completions.append(result)
        }
        try rescopeToReplacementForeground(fixture, router: foregroundRouter)
        try await waitForRecoveryRoute(
            store: fixture.store,
            capturedOwner: secondaryRouter,
            currentForeground: foregroundRouter
        )

        let capturedOwnerRequests = await secondaryRouter.workspaceListGate.requestCount()
        let currentForegroundRequests = await foregroundRouter.workspaceListGate.requestCount()
        #expect(capturedOwnerRequests == 1)
        #expect(currentForegroundRequests == 0)
        #expect(completions.isEmpty, "failure must wait for the captured owner's response")
        #expect(fixture.store.terminalReorderGate.requiresRefresh(
            workspaceID: fixture.secondaryWorkspaceID
        ))
        guard capturedOwnerRequests == 1, currentForegroundRequests == 0 else { return }

        await secondaryRouter.workspaceListGate.releaseFirst()
        try await waitForTerminalCreationOwnerToFinish(fixture.store)

        #expect(completions.count == 1)
        guard completions.count == 1 else { return }
        guard case let .failure(.appliedNeedsRefresh(hostDisplayName)) = completions[0] else {
            Issue.record("captured owner rejection should require refresh: \(completions[0])")
            return
        }
        #expect(hostDisplayName == "Secondary Mac")
        #expect(fixture.store.terminalReorderGate.requiresRefresh(
            workspaceID: fixture.secondaryWorkspaceID
        ))
        #expect(!fixture.store.terminalReorderGate.canMutate(
            workspaceID: fixture.secondaryWorkspaceID
        ))
    }

    private struct SecondaryRecoveryFixture {
        let store: MobileShellComposite
        let secondaryWorkspaceID: MobileWorkspacePreview.ID
        let replacementWorkspace: MobileWorkspacePreview
        let actionCapabilities: MobileWorkspaceActionCapabilities
    }

    private func makeSecondaryRecoveryStore(
        foregroundRouter: RoutingHostRouter,
        secondaryRouter: RoutingHostRouter
    ) async throws -> SecondaryRecoveryFixture {
        let secondaryRoute = try CmxAttachRoute(
            id: "debug_loopback_secondary-mac",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56587)
        )
        let pairedMacStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [
                    MobilePairedMac(
                        macDeviceID: "secondary-mac",
                        displayName: "Secondary Mac",
                        routes: [secondaryRoute],
                        createdAt: Date(timeIntervalSince1970: 1),
                        lastSeenAt: Date(timeIntervalSince1970: 2),
                        isActive: false,
                        stackUserID: "user-1",
                        teamID: "team-a"
                    ),
                ],
            ],
            blockedTeams: []
        )
        let store = makeRoutingMultiMacStore(
            router: foregroundRouter,
            pairedMacStore: pairedMacStore
        )
        try installSecondaryClient(
            on: store,
            macDeviceID: "secondary-mac",
            router: secondaryRouter
        )
        let capabilities = MobileWorkspaceActionCapabilities(
            supportsTerminalCloseActions: true,
            supportsTerminalCreateInPane: true,
            supportsTerminalReorderActions: true
        )
        var sourceWorkspace = MobileWorkspacePreview(
            id: .init(rawValue: RoutingHostRouter.workspaceID),
            name: "Routing Workspace",
            terminals: [
                MobileTerminalPreview(
                    id: .init(rawValue: RoutingHostRouter.terminalA),
                    name: "A"
                ),
                MobileTerminalPreview(
                    id: .init(rawValue: RoutingHostRouter.terminalB),
                    name: "B"
                ),
            ]
        )
        sourceWorkspace.actionCapabilities = capabilities
        var foregroundWorkspace = sourceWorkspace
        foregroundWorkspace.macDeviceID = "foreground-mac"
        foregroundWorkspace.name = "Foreground collision"
        var secondaryWorkspace = sourceWorkspace
        secondaryWorkspace.macDeviceID = "secondary-mac"
        secondaryWorkspace.name = "Secondary collision"
        store.setWorkspaceStatesForTesting(
            [
                "foreground-mac": MacWorkspaceState(
                    macDeviceID: "foreground-mac",
                    displayName: "Foreground Mac",
                    workspaces: [foregroundWorkspace],
                    status: .connected,
                    actionCapabilities: capabilities
                ),
                "secondary-mac": MacWorkspaceState(
                    macDeviceID: "secondary-mac",
                    displayName: "Secondary Mac",
                    workspaces: [secondaryWorkspace],
                    status: .connected,
                    actionCapabilities: capabilities
                ),
            ],
            foregroundMacDeviceID: "foreground-mac"
        )
        let secondaryWorkspaceID = try #require(
            store.workspaces.first(where: { $0.macDeviceID == "secondary-mac" })?.id
        )
        store.terminalReorderGate.requireRefresh(workspaceID: secondaryWorkspaceID)
        return SecondaryRecoveryFixture(
            store: store,
            secondaryWorkspaceID: secondaryWorkspaceID,
            replacementWorkspace: sourceWorkspace,
            actionCapabilities: capabilities
        )
    }

    private func rescopeToReplacementForeground(
        _ fixture: SecondaryRecoveryFixture,
        router: RoutingHostRouter
    ) throws {
        try installFreshRemoteClient(on: fixture.store, router: router)
        fixture.store.connectedHostName = "Replacement Mac"
        var replacementWorkspace = fixture.replacementWorkspace
        replacementWorkspace.macDeviceID = "test-mac-2"
        replacementWorkspace.name = "Replacement foreground"
        fixture.store.setWorkspaceStatesForTesting(
            [
                "test-mac-2": MacWorkspaceState(
                    macDeviceID: "test-mac-2",
                    displayName: "Replacement Mac",
                    workspaces: [replacementWorkspace],
                    status: .connected,
                    actionCapabilities: fixture.actionCapabilities
                ),
            ],
            foregroundMacDeviceID: "test-mac-2"
        )
    }

    private func waitForRecoveryRoute(
        store: MobileShellComposite,
        capturedOwner: RoutingHostRouter,
        currentForeground: RoutingHostRouter
    ) async throws {
        for _ in 0..<300 {
            let capturedOwnerRequests = await capturedOwner.workspaceListGate.requestCount()
            let currentForegroundRequests = await currentForeground.workspaceListGate.requestCount()
            if capturedOwnerRequests > 0
                || currentForegroundRequests > 0
                || !store.terminalCreationRequestOwner.isActive {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
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
