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
@Test func hierarchyGatePreservesOwnerAcrossOneToMultiRowRescope() throws {
    let store = MobileShellComposite.preview()
    let ownedWorkspace = hierarchyGateWorkspace(macID: "mac-a")
    store.setWorkspaceStatesForTesting(
        ["mac-a": MacWorkspaceState(macDeviceID: "mac-a", workspaces: [ownedWorkspace])],
        foregroundMacDeviceID: "mac-a"
    )
    let rawWorkspaceID = try #require(store.workspaces.first?.id)
    let reservation = try #require(store.terminalReorderGate.reserve(
        workspaceID: rawWorkspaceID,
        paneID: "pane-a"
    ))
    store.terminalReorderGate.requireRefresh(workspaceID: rawWorkspaceID)

    let collidingWorkspace = hierarchyGateWorkspace(macID: "mac-b")
    store.setWorkspaceStatesForTesting(
        [
            "mac-a": MacWorkspaceState(macDeviceID: "mac-a", workspaces: [ownedWorkspace]),
            "mac-b": MacWorkspaceState(macDeviceID: "mac-b", workspaces: [collidingWorkspace]),
        ],
        foregroundMacDeviceID: "mac-a"
    )
    let scopedWorkspaceID = try #require(
        store.workspaces.first(where: { $0.macDeviceID == "mac-a" })?.id
    )

    #expect(scopedWorkspaceID != rawWorkspaceID)
    #expect(reservation.workspaceID == rawWorkspaceID, "reservation payload keeps its presented row")
    #expect(store.terminalReorderGate.isActive(workspaceID: scopedWorkspaceID))
    #expect(store.terminalReorderGate.requiresRefresh(workspaceID: scopedWorkspaceID))
    #expect(store.terminalReorderGate.reserve(
        workspaceID: scopedWorkspaceID,
        paneID: "pane-a"
    ) == nil)

    store.terminalReorderGate.finish(reservation)
    #expect(store.terminalReorderGate.requiresRefresh(workspaceID: scopedWorkspaceID))
    store.terminalReorderGate.reconcileAfterAuthoritativeRefresh(workspaceIDs: [scopedWorkspaceID])
    #expect(store.terminalReorderGate.canMutate(workspaceID: scopedWorkspaceID))
}

@MainActor
@Test func hierarchyGatePreservesOwnerAcrossMultiToOneRowDescope() throws {
    let store = MobileShellComposite.preview()
    let ownedWorkspace = hierarchyGateWorkspace(macID: "mac-a")
    let collidingWorkspace = hierarchyGateWorkspace(macID: "mac-b")
    store.setWorkspaceStatesForTesting(
        [
            "mac-a": MacWorkspaceState(macDeviceID: "mac-a", workspaces: [ownedWorkspace]),
            "mac-b": MacWorkspaceState(macDeviceID: "mac-b", workspaces: [collidingWorkspace]),
        ],
        foregroundMacDeviceID: "mac-a"
    )
    let scopedWorkspaceID = try #require(
        store.workspaces.first(where: { $0.macDeviceID == "mac-a" })?.id
    )
    let reservation = try #require(store.terminalReorderGate.reserve(
        workspaceID: scopedWorkspaceID,
        paneID: "pane-a"
    ))
    store.terminalReorderGate.requireRefresh(workspaceID: scopedWorkspaceID)

    store.setWorkspaceStatesForTesting(
        ["mac-a": MacWorkspaceState(macDeviceID: "mac-a", workspaces: [ownedWorkspace])],
        foregroundMacDeviceID: "mac-a"
    )
    let rawWorkspaceID = try #require(store.workspaces.first?.id)

    #expect(rawWorkspaceID != scopedWorkspaceID)
    #expect(reservation.workspaceID == scopedWorkspaceID, "reservation payload keeps its presented row")
    #expect(store.terminalReorderGate.isActive(workspaceID: rawWorkspaceID))
    #expect(store.terminalReorderGate.requiresRefresh(workspaceID: rawWorkspaceID))
    #expect(store.terminalReorderGate.reserve(
        workspaceID: rawWorkspaceID,
        paneID: "pane-a"
    ) == nil)

    store.terminalReorderGate.finish(reservation)
    #expect(store.terminalReorderGate.requiresRefresh(workspaceID: rawWorkspaceID))
    store.terminalReorderGate.reconcileAfterAuthoritativeRefresh(workspaceIDs: [rawWorkspaceID])
    #expect(store.terminalReorderGate.canMutate(workspaceID: rawWorkspaceID))
}

@MainActor
@Test func hierarchyGateMigratesActiveReservationAcrossOwnerAdoption() throws {
    let gate = MobileTerminalReorderGate()
    let anonymousWorkspace = hierarchyGateWorkspace(macID: nil)
    let durableWorkspace = hierarchyGateWorkspace(macID: "mac-adopted")
    gate.updateWorkspacePresentationIdentities([anonymousWorkspace])
    let reservation = try #require(gate.reserve(
        workspaceID: anonymousWorkspace.id,
        paneID: "pane-adoption"
    ))
    #expect(reservation.ownerIdentity.ownerMacID == nil)

    gate.updateWorkspacePresentationIdentities([durableWorkspace])

    #expect(reservation.ownerIdentity.ownerMacID == nil, "reservation ownership stays immutable")
    #expect(gate.isActive(workspaceID: durableWorkspace.id))
    #expect(gate.owns(reservation))
    let duplicate = gate.reserve(
        workspaceID: durableWorkspace.id,
        paneID: "pane-adoption"
    )
    #expect(duplicate == nil)
    if let duplicate { gate.finish(duplicate) }

    gate.finish(reservation)

    #expect(!gate.isActive)
    #expect(gate.canMutate(workspaceID: durableWorkspace.id))
}

@MainActor
@Test func hierarchyGateMigratesRefreshFenceAcrossOwnerAdoption() {
    let gate = MobileTerminalReorderGate()
    let anonymousWorkspace = hierarchyGateWorkspace(macID: nil)
    let durableWorkspace = hierarchyGateWorkspace(macID: "mac-adopted")
    gate.updateWorkspacePresentationIdentities([anonymousWorkspace])
    gate.requireRefresh(workspaceID: anonymousWorkspace.id)

    gate.updateWorkspacePresentationIdentities([durableWorkspace])

    #expect(gate.requiresRefresh(workspaceID: durableWorkspace.id))
    #expect(!gate.canMutate(workspaceID: durableWorkspace.id))

    gate.reconcileAfterAuthoritativeRefresh(workspaceIDs: [durableWorkspace.id])

    #expect(gate.refreshRequiredWorkspaceIDs.isEmpty)
    #expect(gate.canMutate(workspaceID: durableWorkspace.id))
}

@MainActor
@Test func hierarchyGateMigratesRecoveryAcrossOwnerAdoption() {
    let gate = MobileTerminalReorderGate()
    let anonymousWorkspace = hierarchyGateWorkspace(macID: nil)
    let durableWorkspace = hierarchyGateWorkspace(macID: "mac-adopted")
    let originalRecoveryWorkspaceID = anonymousWorkspace.id
    gate.updateWorkspacePresentationIdentities([anonymousWorkspace])
    gate.requireRefresh(workspaceID: originalRecoveryWorkspaceID)
    #expect(gate.beginRecovery(workspaceID: originalRecoveryWorkspaceID))

    gate.updateWorkspacePresentationIdentities([durableWorkspace])

    #expect(gate.isActive(workspaceID: durableWorkspace.id))
    #expect(gate.requiresRefresh(workspaceID: durableWorkspace.id))
    let duplicate = gate.reserve(
        workspaceID: durableWorkspace.id,
        paneID: "pane-adoption"
    )
    #expect(duplicate == nil)
    if let duplicate { gate.finish(duplicate) }

    gate.finishRecovery(workspaceID: originalRecoveryWorkspaceID, succeeded: true)

    #expect(!gate.isActive)
    #expect(gate.refreshRequiredWorkspaceIDs.isEmpty)
    #expect(gate.canMutate(workspaceID: durableWorkspace.id))
}

@MainActor
@Test func hierarchyGateMigratesActiveReservationAcrossScopedOwnerAdoption() throws {
    let fixture = try hierarchyGateScopedOwnerAdoptionFixture()
    let reservation = try #require(fixture.store.terminalReorderGate.reserve(
        workspaceID: fixture.anonymousRowID,
        paneID: "pane-adoption"
    ))

    fixture.store.adoptForegroundMacIdentity("mac-adopted")
    let adoptedRowID = try hierarchyGateAdoptedRowID(in: fixture.store)

    #expect(fixture.anonymousRowID != adoptedRowID)
    #expect(fixture.anonymousRowID.rawValue == "__cmux_foreground__\u{1F}workspace-stable")
    #expect(adoptedRowID.rawValue == "mac-adopted\u{1F}workspace-stable")
    #expect(reservation.workspaceID == fixture.anonymousRowID)
    #expect(reservation.ownerIdentity.ownerMacID == nil)
    #expect(fixture.store.terminalReorderGate.isActive(workspaceID: adoptedRowID))
    #expect(fixture.store.terminalReorderGate.owns(reservation))
    let duplicate = fixture.store.terminalReorderGate.reserve(
        workspaceID: adoptedRowID,
        paneID: "pane-adoption"
    )
    #expect(duplicate == nil)
    if let duplicate { fixture.store.terminalReorderGate.finish(duplicate) }

    fixture.store.terminalReorderGate.finish(reservation)

    #expect(!fixture.store.terminalReorderGate.isActive)
    #expect(fixture.store.terminalReorderGate.canMutate(workspaceID: adoptedRowID))
}

@MainActor
@Test func hierarchyGateMigratesRefreshFenceAcrossScopedOwnerAdoption() throws {
    let fixture = try hierarchyGateScopedOwnerAdoptionFixture()
    fixture.store.terminalReorderGate.requireRefresh(workspaceID: fixture.anonymousRowID)

    fixture.store.adoptForegroundMacIdentity("mac-adopted")
    let adoptedRowID = try hierarchyGateAdoptedRowID(in: fixture.store)

    #expect(fixture.anonymousRowID != adoptedRowID)
    #expect(fixture.anonymousRowID.rawValue == "__cmux_foreground__\u{1F}workspace-stable")
    #expect(adoptedRowID.rawValue == "mac-adopted\u{1F}workspace-stable")
    #expect(fixture.store.terminalReorderGate.requiresRefresh(workspaceID: adoptedRowID))
    #expect(!fixture.store.terminalReorderGate.canMutate(workspaceID: adoptedRowID))

    fixture.store.terminalReorderGate.reconcileAfterAuthoritativeRefresh(
        workspaceIDs: [adoptedRowID]
    )

    #expect(fixture.store.terminalReorderGate.refreshRequiredWorkspaceIDs.isEmpty)
    #expect(fixture.store.terminalReorderGate.canMutate(workspaceID: adoptedRowID))
}

@MainActor
@Test func hierarchyGateMigratesRecoveryAcrossScopedOwnerAdoption() throws {
    let fixture = try hierarchyGateScopedOwnerAdoptionFixture()
    fixture.store.terminalReorderGate.requireRefresh(workspaceID: fixture.anonymousRowID)
    #expect(fixture.store.terminalReorderGate.beginRecovery(
        workspaceID: fixture.anonymousRowID
    ))

    fixture.store.adoptForegroundMacIdentity("mac-adopted")
    let adoptedRowID = try hierarchyGateAdoptedRowID(in: fixture.store)

    #expect(fixture.anonymousRowID != adoptedRowID)
    #expect(fixture.anonymousRowID.rawValue == "__cmux_foreground__\u{1F}workspace-stable")
    #expect(adoptedRowID.rawValue == "mac-adopted\u{1F}workspace-stable")
    #expect(fixture.store.terminalReorderGate.isActive(workspaceID: adoptedRowID))
    #expect(fixture.store.terminalReorderGate.requiresRefresh(workspaceID: adoptedRowID))
    let duplicate = fixture.store.terminalReorderGate.reserve(
        workspaceID: adoptedRowID,
        paneID: "pane-adoption"
    )
    #expect(duplicate == nil)
    if let duplicate { fixture.store.terminalReorderGate.finish(duplicate) }

    fixture.store.terminalReorderGate.finishRecovery(
        workspaceID: adoptedRowID,
        succeeded: true
    )

    #expect(!fixture.store.terminalReorderGate.isActive)
    #expect(fixture.store.terminalReorderGate.refreshRequiredWorkspaceIDs.isEmpty)
    #expect(fixture.store.terminalReorderGate.canMutate(workspaceID: adoptedRowID))
}

@MainActor
private func hierarchyGateScopedOwnerAdoptionFixture() throws -> (
    store: MobileShellComposite,
    anonymousRowID: MobileWorkspacePreview.ID
) {
    let store = MobileShellComposite.preview()
    let anonymousWorkspace = hierarchyGateWorkspace(macID: nil)
    let secondaryWorkspace = hierarchyGateWorkspace(
        macID: "mac-secondary",
        id: "workspace-secondary"
    )
    store.setWorkspaceStatesForTesting(
        [
            MobileShellComposite.foregroundAnonymousKey: MacWorkspaceState(
                macDeviceID: MobileShellComposite.foregroundAnonymousKey,
                workspaces: [anonymousWorkspace]
            ),
            "mac-secondary": MacWorkspaceState(
                macDeviceID: "mac-secondary",
                workspaces: [secondaryWorkspace]
            ),
        ],
        foregroundMacDeviceID: nil
    )
    let anonymousRowID = try #require(
        store.workspaces.first(where: { $0.rpcWorkspaceID == anonymousWorkspace.id })?.id
    )
    return (store, anonymousRowID)
}

@MainActor
private func hierarchyGateAdoptedRowID(
    in store: MobileShellComposite
) throws -> MobileWorkspacePreview.ID {
    try #require(
        store.workspaces.first(where: { workspace in
            workspace.rpcWorkspaceID == "workspace-stable"
                && workspace.macDeviceID == "mac-adopted"
        })?.id
    )
}

private func hierarchyGateWorkspace(
    macID: String?,
    id: MobileWorkspacePreview.ID = "workspace-stable"
) -> MobileWorkspacePreview {
    MobileWorkspacePreview(
        id: id,
        macDeviceID: macID,
        name: "Stable Workspace",
        terminals: []
    )
}
