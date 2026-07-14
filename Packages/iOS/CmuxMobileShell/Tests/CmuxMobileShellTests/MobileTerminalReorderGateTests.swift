import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func remoteTerminalCreationSerializesWithCloseAndReorder() throws {
    let store = MobileShellComposite.preview()
    var workspace = try #require(store.workspaces.first)
    let paneID = MobilePanePreview.ID(rawValue: "pane-create")
    workspace.panes = [
        MobilePanePreview(
            id: paneID,
            spatialIndex: 0,
            terminalIDs: workspace.terminals.map(\.id)
        ),
    ]
    workspace.actionCapabilities = MobileWorkspaceActionCapabilities(
        supportsTerminalCloseActions: true,
        supportsTerminalCreateInPane: true,
        supportsTerminalReorderActions: true
    )

    let claim = store.claimTerminalCreationMutation(in: workspace, paneID: paneID)

    #expect(store.terminalReorderGate.isActive)
    #expect(store.terminalReorderGate.reserve(workspaceID: workspace.id, paneID: paneID) == nil)
    guard case .reserved(let reservation) = claim else {
        return #expect(Bool(false), "modern terminal create must reserve the hierarchy gate")
    }
    store.terminalReorderGate.finish(reservation)
    #expect(store.terminalReorderGate.canMutate(workspaceID: workspace.id))
}

@MainActor
@Test func duplicateTerminalCreationStartFailsClosedAndReleasesItsClaim() async throws {
    let owner = MobileTerminalCreationRequestOwner()
    let gate = MobileTerminalReorderGate()
    var firstStarted = false
    var firstRelease: CheckedContinuation<Void, Never>?
    var duplicateRan = false

    let firstAccepted = owner.startIfIdle(claim: .unreserved, gate: gate) {
        firstStarted = true
        guard !Task.isCancelled else { return }
        await withCheckedContinuation { firstRelease = $0 }
    }
    defer {
        firstRelease?.resume()
        owner.cancel(gate: gate)
    }
    for _ in 0..<100 where !firstStarted {
        await Task.yield()
    }
    #expect(firstStarted)
    guard firstStarted else { return }
    let duplicateReservation = try #require(gate.reserve(
        workspaceID: "duplicate-workspace",
        paneID: "duplicate-pane"
    ))

    let duplicateAccepted = owner.startIfIdle(
        claim: .reserved(duplicateReservation),
        gate: gate
    ) {
        duplicateRan = true
    }

    #expect(firstAccepted)
    #expect(!duplicateAccepted)
    #expect(!duplicateRan)
    #expect(owner.isActive)
    #expect(gate.canMutate(workspaceID: "duplicate-workspace"))

    firstRelease?.resume()
    firstRelease = nil
    for _ in 0..<100 where owner.isActive {
        await Task.yield()
    }
    #expect(!owner.isActive)
}

@MainActor
@Test func rejectedReorderReleasesItsReservation() async throws {
    let store = MobileShellComposite.preview()
    let pane = MobilePanePreview(
        id: "missing-pane",
        spatialIndex: 0,
        terminalIDs: ["terminal-a", "terminal-b"]
    )
    let intent = try #require(MobileTerminalReorderIntent(
        terminalID: "terminal-a",
        sourceIndex: 0,
        destinationIndex: 2,
        pane: pane
    ))
    let reservation = try #require(store.terminalReorderGate.reserve(
        workspaceID: "missing-workspace",
        paneID: pane.id
    ))

    _ = await store.reorderTerminal(
        workspaceID: "missing-workspace",
        intent: intent,
        reservation: reservation
    )

    #expect(store.terminalReorderGate.canMutate(workspaceID: "missing-workspace"))
}

@MainActor
@Test func malformedPaneMembershipRejectsReorderBeforeRPC() async throws {
    let router = RoutingHostRouter()
    let capabilities = MobileWorkspaceActionCapabilities(
        supportsTerminalReorderActions: true
    )
    let store = try await makeRoutingConnectedStore(
        router: router,
        connectionState: .connected,
        workspaceActionCapabilities: capabilities
    )
    var workspace = MobileWorkspacePreview(
        id: .init(rawValue: RoutingHostRouter.workspaceID),
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        name: "Malformed reorder",
        terminals: [
            MobileTerminalPreview(id: "terminal-a", name: "A", paneID: "pane-a"),
            MobileTerminalPreview(id: "terminal-b", name: "B", paneID: "pane-a"),
            MobileTerminalPreview(id: "terminal-d", name: "D", paneID: "pane-a"),
        ],
        panes: [
            MobilePanePreview(
                id: "pane-a",
                spatialIndex: 0,
                terminalIDs: ["terminal-a", "terminal-missing", "terminal-b", "terminal-d"]
            ),
        ]
    )
    workspace.actionCapabilities = capabilities
    store.setWorkspaceStatesForTesting(
        [
            "test-mac": MacWorkspaceState(
                macDeviceID: "test-mac",
                displayName: "Test Mac",
                workspaces: [workspace],
                status: .connected,
                actionCapabilities: capabilities
            ),
        ],
        foregroundMacDeviceID: "test-mac"
    )
    let pane = try #require(workspace.panes.first)
    let intent = try #require(MobileTerminalReorderIntent(
        terminalID: "terminal-b",
        sourceIndex: 2,
        destinationIndex: 4,
        pane: pane
    ))
    let reservation = try #require(store.terminalReorderGate.reserve(
        workspaceID: workspace.id,
        paneID: pane.id
    ))

    let result = await store.reorderTerminal(
        workspaceID: workspace.id,
        intent: intent,
        reservation: reservation
    )

    guard case .failure(.rejected) = result else {
        Issue.record("Expected malformed membership rejection, got \(result)")
        return
    }
    #expect(await router.recordedTerminalReorderCount() == 0)
    #expect(store.terminalReorderGate.canMutate(workspaceID: workspace.id))
}

@MainActor
@Test func rejectedCloseReleasesItsReservation() async throws {
    let store = MobileShellComposite.preview()
    let reservation = try #require(store.terminalReorderGate.reserve(
        workspaceID: "missing-workspace",
        paneID: "missing-pane"
    ))

    _ = await store.closeTerminal(
        workspaceID: "missing-workspace",
        terminalID: "missing-terminal",
        confirmed: false,
        reservation: reservation
    )

    #expect(store.terminalReorderGate.canMutate(workspaceID: "missing-workspace"))
}

@MainActor
@Test func stalePaneCloseReservationRejectsBeforeRPC() async throws {
    let router = RoutingHostRouter()
    let capabilities = MobileWorkspaceActionCapabilities(
        supportsTerminalCloseActions: true
    )
    let store = try await makeRoutingConnectedStore(
        router: router,
        connectionState: .connected,
        workspaceActionCapabilities: capabilities
    )
    let workspaceID = MobileWorkspacePreview.ID(rawValue: RoutingHostRouter.workspaceID)
    let terminalID = MobileTerminalPreview.ID(rawValue: RoutingHostRouter.terminalA)
    let originalPaneID = MobilePanePreview.ID(rawValue: "pane-original")
    let currentPaneID = MobilePanePreview.ID(rawValue: "pane-current")
    let reservation = try #require(store.terminalReorderGate.reserve(
        workspaceID: workspaceID,
        paneID: originalPaneID
    ))
    var movedWorkspace = MobileWorkspacePreview(
        id: workspaceID,
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        name: "Moved terminal",
        terminals: [
            MobileTerminalPreview(
                id: terminalID,
                name: "Moved",
                paneID: currentPaneID
            ),
        ],
        panes: [
            MobilePanePreview(
                id: currentPaneID,
                spatialIndex: 0,
                terminalIDs: [terminalID]
            ),
        ]
    )
    movedWorkspace.actionCapabilities = capabilities
    store.setWorkspaceStatesForTesting(
        [
            "test-mac": MacWorkspaceState(
                macDeviceID: "test-mac",
                displayName: "Test Mac",
                workspaces: [movedWorkspace],
                status: .connected,
                actionCapabilities: capabilities
            ),
        ],
        foregroundMacDeviceID: "test-mac"
    )

    let result = await store.closeTerminal(
        workspaceID: workspaceID,
        terminalID: terminalID,
        confirmed: false,
        reservation: reservation
    )

    guard case .failure(.busy) = result else {
        Issue.record("Expected stale pane reservation rejection, got \(result)")
        return
    }
    #expect(await router.recordedTerminalCloseCount() == 0)
    #expect(store.terminalReorderGate.canMutate(workspaceID: workspaceID))
}

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
@Test func ambiguousCloseFailureStillReconcilesAndReleasesReservation() async throws {
    let router = RoutingHostRouter()
    await router.setDropTerminalCloseResponse(true)
    let store = try await makeRoutingConnectedStore(
        router: router,
        connectionState: .connected,
        rpcRequestTimeoutNanoseconds: 20_000_000,
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
    let result = await close.value

    guard case .failure(.resultUnknownRefreshed) = result else {
        Issue.record("Expected reconciled unknown result, got \(result)")
        return
    }
    #expect(await router.recordedTerminalCloseCount() == 1)
    #expect(await router.workspaceListGate.requestCount() == 1)
    #expect(store.terminalReorderGate.canMutate(workspaceID: workspace.id))
}
