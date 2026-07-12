import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func reorderReservationSurvivesHierarchySheetRecreation() throws {
    let store = MobileShellComposite.preview()
    let firstSheetGate = store.terminalReorderGate

    let reservation = try #require(
        firstSheetGate.reserve(workspaceID: "workspace", paneID: "pane-left")
    )

    let reopenedSheetGate = store.terminalReorderGate
    #expect(reopenedSheetGate === firstSheetGate)
    #expect(reopenedSheetGate.isActive)
    #expect(reopenedSheetGate.reserve(workspaceID: "workspace", paneID: "pane-right") == nil)

    reopenedSheetGate.finish(reservation)
    #expect(!firstSheetGate.isActive)
}

@MainActor
@Test func hierarchyMutationGateStaysClosedUntilRecoverySucceeds() throws {
    let gate = MobileTerminalReorderGate()
    let closeReservation = try #require(
        gate.reserve(workspaceID: "workspace", paneID: "pane-left")
    )

    #expect(gate.reserve(workspaceID: "workspace", paneID: "pane-right") == nil)
    gate.requireRefresh(workspaceID: "workspace")
    gate.finish(closeReservation)
    #expect(!gate.canMutate(workspaceID: "workspace"))
    #expect(gate.canMutate(workspaceID: "other-workspace"))

    #expect(!gate.beginRecovery(workspaceID: "other-workspace"))
    gate.requireRefresh(workspaceID: "other-workspace")
    #expect(gate.beginRecovery(workspaceID: "workspace"))
    gate.finishRecovery(workspaceID: "workspace", succeeded: false)
    #expect(!gate.canMutate(workspaceID: "workspace"))

    #expect(gate.beginRecovery(workspaceID: "workspace"))
    gate.finishRecovery(workspaceID: "workspace", succeeded: true)
    #expect(gate.canMutate(workspaceID: "workspace"))
    #expect(!gate.canMutate(workspaceID: "other-workspace"))

    #expect(gate.beginRecovery(workspaceID: "other-workspace"))
    gate.finishRecovery(workspaceID: "other-workspace", succeeded: true)
    #expect(gate.canMutate(workspaceID: "other-workspace"))
}

@MainActor
@Test func authoritativeRefreshReopensAndPrunesHierarchyMutationGates() {
    let gate = MobileTerminalReorderGate()
    gate.requireRefresh(workspaceID: "refreshed-workspace")
    gate.requireRefresh(workspaceID: "removed-workspace")
    gate.requireRefresh(workspaceID: "other-mac-workspace")

    gate.reconcileAfterAuthoritativeRefresh(
        workspaceIDs: ["refreshed-workspace", "removed-workspace"]
    )

    #expect(gate.canMutate(workspaceID: "refreshed-workspace"))
    #expect(gate.canMutate(workspaceID: "removed-workspace"))
    #expect(!gate.canMutate(workspaceID: "other-mac-workspace"))
}

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
    store.finishTerminalCreationMutation(claim)
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
        await withCheckedContinuation { firstRelease = $0 }
    }
    while !firstStarted {
        await Task.yield()
    }
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
@Test func definiteCloseFailuresSkipRefreshAndReleaseReservation() async throws {
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
        #expect(await router.workspaceListGate.requestCount() == 0)
        #expect(store.terminalReorderGate.canMutate(workspaceID: workspace.id))
    }
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
