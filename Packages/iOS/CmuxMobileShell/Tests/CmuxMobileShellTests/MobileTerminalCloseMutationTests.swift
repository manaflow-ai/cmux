import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func closeFallbackUsesReportedPaneMembershipWhenTerminalPaneIDIsMissing() async throws {
    let router = RoutingHostRouter()
    await router.setUsesNilPaneIDCloseFallbackFixture(true)
    let capabilities = MobileWorkspaceActionCapabilities(
        supportsTerminalCloseActions: true
    )
    let store = try await makeRoutingConnectedStore(
        router: router,
        connectionState: .connected,
        workspaceActionCapabilities: capabilities
    )
    let workspaceID = MobileWorkspacePreview.ID(rawValue: RoutingHostRouter.workspaceID)
    let leftAID = MobileTerminalPreview.ID(rawValue: RoutingHostRouter.closeFallbackLeftA)
    let targetID = MobileTerminalPreview.ID(rawValue: RoutingHostRouter.closeFallbackTarget)
    let rightID = MobileTerminalPreview.ID(rawValue: RoutingHostRouter.closeFallbackRight)
    let leftCID = MobileTerminalPreview.ID(rawValue: RoutingHostRouter.closeFallbackLeftC)
    let workspace = MobileWorkspacePreview(
        id: workspaceID,
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        name: "Nil pane ID fallback",
        terminals: [
            MobileTerminalPreview(id: leftAID, name: "Left A"),
            MobileTerminalPreview(id: targetID, name: "Target"),
            MobileTerminalPreview(id: rightID, name: "Right"),
            MobileTerminalPreview(id: leftCID, name: "Left C"),
        ],
        panes: [
            MobilePanePreview(
                id: "pane-left",
                spatialIndex: 0,
                isFocused: true,
                terminalIDs: [
                    leftAID,
                    targetID,
                    leftCID,
                ]
            ),
            MobilePanePreview(
                id: "pane-right",
                spatialIndex: 1,
                terminalIDs: [
                    rightID,
                ]
            ),
        ],
        focusedPaneID: "pane-left",
        selectedTerminalID: targetID
    )
    var actionableWorkspace = workspace
    actionableWorkspace.actionCapabilities = capabilities
    store.setWorkspaceStatesForTesting(
        [
            "test-mac": MacWorkspaceState(
                macDeviceID: "test-mac",
                displayName: "Test Mac",
                workspaces: [actionableWorkspace],
                status: .connected,
                actionCapabilities: capabilities
            ),
        ],
        foregroundMacDeviceID: "test-mac"
    )
    store.selectedWorkspaceID = workspaceID
    store.selectTerminal(targetID)
    let reservation = try #require(store.terminalReorderGate.reserve(
        workspaceID: workspaceID,
        paneID: "pane-left"
    ))

    let result = await store.closeTerminal(
        workspaceID: workspaceID,
        terminalID: targetID,
        confirmed: false,
        reservation: reservation
    )

    guard case .success = result else {
        Issue.record("Expected close success, got \(result)")
        return
    }
    #expect(store.selectedTerminalID?.rawValue == RoutingHostRouter.closeFallbackLeftC)
    #expect(await router.recordedTerminalCloseCount() == 1)
    #expect(await router.workspaceListGate.requestCount() == 1)
}

@MainActor
@Test func closePolicyFailuresRefreshOnlyWhenStateMayHaveDiverged() async throws {
    for code in ["protected", "confirmation_required"] {
        let router = RoutingHostRouter()
        await router.setTerminalCloseErrorCode(code)
        let store = try await makeRoutingConnectedStore(
            router: router,
            connectionState: .connected,
            workspaceActionCapabilities: MobileWorkspaceActionCapabilities(
                supportsTerminalCloseActions: true
            )
        )
        let workspace = try #require(store.workspaces.first)
        #expect(workspace.actionCapabilities.supportsTerminalCloseActions)
        #expect(workspace.terminals.contains { $0.id.rawValue == RoutingHostRouter.terminalA && $0.canClose })
        let paneID = try #require(workspace.resolvedPanes.first?.id)
        let reservation = try #require(store.terminalReorderGate.reserve(
            workspaceID: workspace.id,
            paneID: paneID
        ))

        let result = await store.closeTerminal(
            workspaceID: workspace.id,
            terminalID: MobileTerminalPreview.ID(rawValue: RoutingHostRouter.terminalA),
            confirmed: false,
            reservation: reservation
        )

        if code == "protected" {
            guard case .failure(.protected) = result else {
                Issue.record("Expected protected, got \(result)")
                continue
            }
        } else {
            guard case .failure(.confirmationRequired) = result else {
                Issue.record("Expected confirmationRequired, got \(result)")
                continue
            }
        }
        #expect(await router.recordedTerminalCloseCount() == 1)
        #expect(await router.workspaceListGate.requestCount() == (code == "protected" ? 1 : 0))
        #expect(store.terminalReorderGate.canMutate(workspaceID: workspace.id))
    }
}

@MainActor
@Test func notFoundCloseFailureRefreshesOnceAsDefiniteDivergence() async throws {
    let router = RoutingHostRouter()
    await router.setTerminalCloseErrorCode("not_found")
    let store = try await makeRoutingConnectedStore(
        router: router,
        connectionState: .connected,
        workspaceActionCapabilities: MobileWorkspaceActionCapabilities(
            supportsTerminalCloseActions: true
        )
    )
    let workspace = try #require(store.workspaces.first)
    let paneID = try #require(workspace.resolvedPanes.first?.id)
    let reservation = try #require(store.terminalReorderGate.reserve(
        workspaceID: workspace.id,
        paneID: paneID
    ))

    let result = await store.closeTerminal(
        workspaceID: workspace.id,
        terminalID: MobileTerminalPreview.ID(rawValue: RoutingHostRouter.terminalA),
        confirmed: false,
        reservation: reservation
    )

    guard case .failure(.rejected) = result else {
        Issue.record("Expected definite rejected failure, got \(result)")
        return
    }
    #expect(await router.recordedTerminalCloseCount() == 1)
    #expect(await router.workspaceListGate.requestCount() == 1)
    #expect(store.terminalReorderGate.canMutate(workspaceID: workspace.id))
}

@MainActor
@Test func notFoundCloseFailureKeepsHierarchyFencedWhenReconciliationFails() async throws {
    let router = RoutingHostRouter()
    await router.setTerminalCloseErrorCode("not_found")
    await router.setRejectWorkspaceList(true)
    let store = try await makeRoutingConnectedStore(
        router: router,
        connectionState: .connected,
        workspaceActionCapabilities: MobileWorkspaceActionCapabilities(
            supportsTerminalCloseActions: true
        )
    )
    let workspace = try #require(store.workspaces.first)
    let paneID = try #require(workspace.resolvedPanes.first?.id)
    let reservation = try #require(store.terminalReorderGate.reserve(
        workspaceID: workspace.id,
        paneID: paneID
    ))

    let result = await store.closeTerminal(
        workspaceID: workspace.id,
        terminalID: MobileTerminalPreview.ID(rawValue: RoutingHostRouter.terminalA),
        confirmed: false,
        reservation: reservation
    )

    guard case .failure(.staleStateNeedsRefresh) = result else {
        Issue.record("Expected refresh-required failure, got \(result)")
        return
    }
    #expect(await router.recordedTerminalCloseCount() == 1)
    #expect(await router.workspaceListGate.requestCount() == 1)
    #expect(store.terminalReorderGate.requiresRefresh(workspaceID: workspace.id))
    #expect(!store.terminalReorderGate.canMutate(workspaceID: workspace.id))
}

@MainActor
@Test func ambiguousCloseFailureStillReconcilesAndReleasesReservation() async throws {
    let router = RoutingHostRouter()
    await router.setDropTerminalCloseResponse(true)
    let store = try await makeRoutingConnectedStore(
        router: router,
        connectionState: .connected,
        rpcRequestTimeoutNanoseconds: 10_000_000_000,
        subsequentRPCRequestTimeoutNanoseconds: 30_000_000_000,
        workspaceActionCapabilities: MobileWorkspaceActionCapabilities(
            supportsTerminalCloseActions: true
        )
    )
    let workspace = try #require(store.workspaces.first)
    #expect(workspace.actionCapabilities.supportsTerminalCloseActions)
    #expect(workspace.terminals.contains { $0.id.rawValue == RoutingHostRouter.terminalA && $0.canClose })
    let paneID = try #require(workspace.resolvedPanes.first?.id)
    let reservation = try #require(store.terminalReorderGate.reserve(
        workspaceID: workspace.id,
        paneID: paneID
    ))

    let close = Task { @MainActor in
        await store.closeTerminal(
            workspaceID: workspace.id,
            terminalID: MobileTerminalPreview.ID(rawValue: RoutingHostRouter.terminalA),
            confirmed: false,
            reservation: reservation
        )
    }
    await router.awaitTerminalCloseReached()
    await router.workspaceListGate.waitUntilRequestCount(1)
    let result = await close.value

    guard case .failure(.resultUnknownRefreshed) = result else {
        Issue.record("Expected reconciled unknown result, got \(result)")
        return
    }
    #expect(await router.recordedTerminalCloseCount() == 1)
    #expect(await router.workspaceListGate.requestCount() == 1)
    #expect(store.terminalReorderGate.canMutate(workspaceID: workspace.id))
}
