import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func remoteCreateDoesNotSendPresentationOnlyLegacyPaneID() {
    let store = MobileShellComposite.preview()
    var workspace = MobileWorkspacePreview(
        id: "workspace-legacy",
        name: "Legacy project",
        terminals: [MobileTerminalPreview(id: "terminal-a", name: "shell")]
    )
    workspace.actionCapabilities.supportsTerminalCreateInPane = true

    #expect(workspace.terminalCreationPaneID == "workspace-legacy-legacy-pane")
    #expect(store.remoteTerminalCreationPaneID(
        in: workspace,
        explicitPaneID: nil
    ) == nil)
}

@MainActor
@Test func createTerminalFallsBackFromStalePaneWithoutDanglingMembership() throws {
    let store = MobileShellComposite.preview()
    let workspace = MobileWorkspacePreview(
        id: "workspace-pane",
        name: "Pane project",
        terminals: [MobileTerminalPreview(id: "terminal-a", name: "shell", paneID: "pane-live")],
        panes: [
            MobilePanePreview(
                id: "pane-live",
                spatialIndex: 0,
                isFocused: true,
                terminalIDs: ["terminal-a"]
            ),
        ],
        focusedPaneID: "pane-live",
        selectedTerminalID: "terminal-a"
    )
    store.replaceForegroundWorkspaceState([workspace])

    store.createLocalTerminal(in: workspace.id, paneID: "pane-stale")

    let updated = try #require(store.workspaces.first)
    let created = try #require(updated.terminals.last)
    #expect(created.paneID == "pane-live")
    #expect(updated.panes[0].terminalIDs.last == created.id)
}

@MainActor
@Test func remoteCreateFallsBackFromStaleFocusedAndExplicitPaneIDs() {
    let store = MobileShellComposite.preview()
    var workspace = MobileWorkspacePreview(
        id: "workspace-pane",
        name: "Pane project",
        terminals: [MobileTerminalPreview(id: "terminal-a", name: "shell", paneID: "pane-live")],
        panes: [
            MobilePanePreview(
                id: "pane-live",
                spatialIndex: 0,
                isFocused: false,
                terminalIDs: ["terminal-a"]
            ),
        ],
        focusedPaneID: "pane-stale",
        selectedTerminalID: "terminal-a"
    )
    workspace.actionCapabilities.supportsTerminalCreateInPane = true

    #expect(store.remoteTerminalCreationPaneID(
        in: workspace,
        explicitPaneID: "pane-also-stale"
    ) == "pane-live")
}

@MainActor
@Test func remoteCreateDoesNotSelectConcurrentTerminalFromAnotherPane() throws {
    let store = MobileShellComposite.preview()
    let workspace = MobileWorkspacePreview(
        id: "workspace-pane",
        name: "Pane project",
        terminals: [
            MobileTerminalPreview(id: "terminal-selected", name: "shell", paneID: "pane-requested"),
            MobileTerminalPreview(id: "terminal-existing-other", name: "shell", paneID: "pane-other"),
            MobileTerminalPreview(id: "terminal-concurrent-other", name: "shell", paneID: "pane-other"),
        ],
        panes: [
            MobilePanePreview(
                id: "pane-requested",
                spatialIndex: 0,
                isFocused: true,
                terminalIDs: ["terminal-selected"]
            ),
            MobilePanePreview(
                id: "pane-other",
                spatialIndex: 1,
                isFocused: false,
                terminalIDs: ["terminal-existing-other", "terminal-concurrent-other"]
            ),
        ],
        focusedPaneID: "pane-requested",
        selectedTerminalID: "terminal-selected"
    )
    store.replaceForegroundWorkspaceState([workspace])

    let resolved = store.resolvedRemoteTerminalCreationSelection(
        responseCreatedTerminalID: "terminal-transient",
        workspaceID: workspace.id,
        existingTerminalIDs: ["terminal-selected", "terminal-existing-other"],
        paneID: "pane-requested"
    )
    if let resolved {
        store.selectTerminal(resolved)
    }

    #expect(resolved == nil)
    #expect(store.selectedTerminalID == "terminal-selected")
}

@MainActor
@Test func createTerminalDoesNotDuplicateAnExistingIDAfterDeletion() throws {
    let store = MobileShellComposite.preview()
    let workspace = MobileWorkspacePreview(
        id: "workspace-pane",
        name: "Pane project",
        terminals: [
            MobileTerminalPreview(id: "workspace-pane-terminal-2", name: "shell", paneID: "pane-live"),
        ],
        panes: [
            MobilePanePreview(
                id: "pane-live",
                spatialIndex: 0,
                isFocused: true,
                terminalIDs: ["workspace-pane-terminal-2"]
            ),
        ],
        focusedPaneID: "pane-live",
        selectedTerminalID: "workspace-pane-terminal-2"
    )
    store.replaceForegroundWorkspaceState([workspace])

    store.createLocalTerminal(in: workspace.id, paneID: "pane-live")

    let updated = try #require(store.workspaces.first)
    #expect(Set(updated.terminals.map(\.id)).count == updated.terminals.count)
    #expect(updated.terminals.last?.id == "workspace-pane-terminal-3")
}

@MainActor
@Test func createTerminalWithoutPaneCapabilityUsesFocusedLocalPane() throws {
    let store = MobileShellComposite.preview()
    let workspace = MobileWorkspacePreview(
        id: "workspace-pane",
        name: "Pane project",
        terminals: [MobileTerminalPreview(id: "terminal-a", name: "shell", paneID: "pane-live")],
        panes: [
            MobilePanePreview(
                id: "pane-live",
                spatialIndex: 0,
                isFocused: true,
                terminalIDs: ["terminal-a"]
            ),
        ],
        focusedPaneID: "pane-live",
        selectedTerminalID: "terminal-a"
    )
    store.replaceForegroundWorkspaceState([workspace])

    store.createTerminal(in: workspace.id)

    let updated = try #require(store.workspaces.first)
    let created = try #require(updated.terminals.last)
    #expect(created.paneID == "pane-live")
    #expect(updated.panes[0].terminalIDs.last == created.id)
}

@MainActor
@Test func publicLocalCreateHonorsExplicitNonFocusedPaneWithoutCapability() throws {
    let store = MobileShellComposite.preview()
    let workspace = MobileWorkspacePreview(
        id: "workspace-explicit-local-pane",
        name: "Explicit local pane",
        terminals: [
            MobileTerminalPreview(id: "terminal-focused", name: "Focused", paneID: "pane-focused"),
            MobileTerminalPreview(id: "terminal-target", name: "Target", paneID: "pane-target"),
        ],
        panes: [
            MobilePanePreview(
                id: "pane-focused",
                spatialIndex: 0,
                isFocused: true,
                terminalIDs: ["terminal-focused"]
            ),
            MobilePanePreview(
                id: "pane-target",
                spatialIndex: 1,
                isFocused: false,
                terminalIDs: ["terminal-target"]
            ),
        ],
        focusedPaneID: "pane-focused",
        selectedTerminalID: "terminal-focused"
    )
    store.replaceForegroundWorkspaceState([workspace])

    store.createTerminal(in: workspace.id, paneID: "pane-target")

    let updated = try #require(store.workspaces.first)
    let created = try #require(updated.terminals.last)
    #expect(created.paneID == "pane-target")
    #expect(updated.panes[1].terminalIDs.last == created.id)
    #expect(updated.focusedPaneID == "pane-focused")
    #expect(store.selectedTerminalID == created.id)
}

@MainActor
@Test func terminalCreateRoutesToOwningSecondaryMacWithCollidingWorkspaceID() async throws {
    let foregroundRouter = RoutingHostRouter()
    let secondaryRouter = RoutingHostRouter()
    let store = try await makeRoutingConnectedStore(
        router: foregroundRouter,
        connectionState: .connected
    )
    try installSecondaryClient(
        on: store,
        macDeviceID: "secondary-mac",
        router: secondaryRouter
    )

    let foregroundWorkspace = MobileWorkspacePreview(
        id: .init(rawValue: RoutingHostRouter.workspaceID),
        macDeviceID: "test-mac",
        name: "Foreground collision",
        terminals: [MobileTerminalPreview(id: "foreground-terminal", name: "Foreground")]
    )
    let secondaryWorkspace = MobileWorkspacePreview(
        id: .init(rawValue: RoutingHostRouter.workspaceID),
        macDeviceID: "secondary-mac",
        name: "Secondary collision",
        terminals: [
            MobileTerminalPreview(id: .init(rawValue: RoutingHostRouter.terminalA), name: "A"),
            MobileTerminalPreview(id: .init(rawValue: RoutingHostRouter.terminalB), name: "B"),
        ],
        selectedTerminalID: .init(rawValue: RoutingHostRouter.terminalB)
    )
    store.setWorkspaceStatesForTesting(
        [
            "test-mac": MacWorkspaceState(
                macDeviceID: "test-mac",
                displayName: "Foreground Mac",
                workspaces: [foregroundWorkspace],
                status: .connected
            ),
            "secondary-mac": MacWorkspaceState(
                macDeviceID: "secondary-mac",
                displayName: "Secondary Mac",
                workspaces: [secondaryWorkspace],
                status: .connected
            ),
        ],
        foregroundMacDeviceID: "test-mac"
    )
    let secondaryRowID = try #require(
        store.workspaces.first(where: { $0.macDeviceID == "secondary-mac" })?.id
    )
    let foregroundRowID = try #require(
        store.workspaces.first(where: { $0.macDeviceID == "test-mac" })?.id
    )
    store.setSelectedWorkspaceID(secondaryRowID)
    store.selectTerminal(.init(rawValue: RoutingHostRouter.terminalB))

    let result = await withCheckedContinuation { continuation in
        store.createTerminal(in: secondaryRowID) { result in
            continuation.resume(returning: result)
        }
    }

    guard case .success = result else {
        Issue.record("Expected secondary terminal creation to succeed, got \(result)")
        return
    }
    #expect(await foregroundRouter.recordedTerminalCreateCount() == 0)
    #expect(await secondaryRouter.recordedTerminalCreateCount() == 1)
    #expect(await secondaryRouter.recordedTerminalCreateWorkspaceIDs() == [RoutingHostRouter.workspaceID])
    #expect(store.selectedWorkspaceID == secondaryRowID)
    #expect(store.selectedTerminalID?.rawValue == "terminal-route-created")
    #expect(
        store.workspaces.first(where: { $0.id == secondaryRowID })?.terminals.map(\.id.rawValue)
            == [RoutingHostRouter.terminalA, RoutingHostRouter.terminalB, "terminal-route-created"]
    )
    #expect(
        store.workspaces.first(where: { $0.id == foregroundRowID })?.terminals.map(\.id.rawValue)
            == ["foreground-terminal"]
    )
}

@MainActor
@Test func secondaryPublicCreateCompletionWaitsForTrailingAuthoritativeList() async throws {
    let router = RoutingHostRouter()
    await router.workspaceListGate.setHoldFirst(true)
    let macID = "secondary-create-authority"
    let route = try CmxAttachRoute(
        id: "debug_loopback_secondary_create_authority",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56587)
    )
    let pairedMacStore = DelayedTeamPairedMacStore(
        recordsByTeam: [
            "team-a": [
                MobilePairedMac(
                    macDeviceID: macID,
                    displayName: "Secondary Mac",
                    routes: [route],
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
    let store = makeRoutingMultiMacStore(router: router, pairedMacStore: pairedMacStore)
    let capabilities = MobileWorkspaceActionCapabilities(
        supportsTerminalCloseActions: true,
        supportsTerminalCreateInPane: true,
        supportsTerminalReorderActions: true
    )
    try installSecondaryClient(
        on: store,
        macDeviceID: macID,
        router: router,
        actionCapabilities: capabilities
    )
    var workspace = MobileWorkspacePreview(
        id: .init(rawValue: RoutingHostRouter.workspaceID),
        macDeviceID: macID,
        name: "Routing Workspace",
        terminals: [
            MobileTerminalPreview(id: .init(rawValue: RoutingHostRouter.terminalA), name: "A"),
            MobileTerminalPreview(id: .init(rawValue: RoutingHostRouter.terminalB), name: "B"),
        ],
        selectedTerminalID: .init(rawValue: RoutingHostRouter.terminalB)
    )
    workspace.actionCapabilities = capabilities
    store.setWorkspaceStatesForTesting(
        [macID: MacWorkspaceState(
            macDeviceID: macID,
            displayName: "Secondary Mac",
            workspaces: [workspace],
            status: .connected,
            actionCapabilities: capabilities
        )],
        foregroundMacDeviceID: "foreground-mac"
    )
    let rowID = try #require(store.workspaces.first?.id)
    var completions: [Result<Void, MobileWorkspaceMutationFailure>] = []

    store.createTerminal(in: rowID) { result in
        completions.append(result)
    }
    await router.workspaceListGate.waitUntilFirstReached()

    #expect(store.workspaces.first?.terminals.contains(where: {
        $0.id.rawValue == "terminal-route-created"
    }) == true, "the mutation-scoped create response should remain immediately visible")
    #expect(completions.isEmpty, "public create completion must wait for post-mutation authority")
    #expect(store.terminalCreationRequestOwner.isActive)
    #expect(store.terminalReorderGate.isActive(workspaceID: rowID))
    #expect(!store.terminalReorderGate.canMutate(workspaceID: rowID))

    await router.workspaceListGate.releaseFirst()
    for _ in 0..<300 where store.terminalCreationRequestOwner.isActive {
        try await Task.sleep(for: .milliseconds(1))
    }

    #expect(await router.workspaceListGate.requestCount() == 1)
    #expect(completions.count == 1)
    guard completions.count == 1 else { return }
    guard case .success = completions[0] else {
        Issue.record("authoritative secondary create should succeed: \(completions[0])")
        return
    }
    #expect(!store.terminalCreationRequestOwner.isActive)
    #expect(store.terminalReorderGate.canMutate(workspaceID: rowID))
}

@MainActor
@Test func secondaryTerminalCreatePreservesSiblingWorkspaceOrderStateAndFocusRevision() async throws {
    let foregroundRouter = RoutingHostRouter()
    let secondaryRouter = RoutingHostRouter()
    let store = try await makeRoutingConnectedStore(
        router: foregroundRouter,
        connectionState: .connected
    )
    let secondaryMacID = "secondary-mac"
    try installSecondaryClient(
        on: store,
        macDeviceID: secondaryMacID,
        router: secondaryRouter
    )

    let foregroundWorkspace = MobileWorkspacePreview(
        id: "foreground-workspace",
        macDeviceID: "test-mac",
        name: "Foreground",
        terminals: []
    )
    let siblingWorkspace = MobileWorkspacePreview(
        id: "secondary-sibling",
        macDeviceID: secondaryMacID,
        name: "Sibling",
        terminals: [
            MobileTerminalPreview(id: "sibling-a", name: "A", paneID: "sibling-pane", isFocused: true),
            MobileTerminalPreview(id: "sibling-b", name: "B", paneID: "sibling-pane"),
        ],
        panes: [
            MobilePanePreview(
                id: "sibling-pane",
                spatialIndex: 0,
                isFocused: true,
                terminalIDs: ["sibling-a", "sibling-b"]
            ),
        ],
        focusedPaneID: "sibling-pane",
        selectedTerminalID: "sibling-a"
    )
    let targetWorkspace = MobileWorkspacePreview(
        id: .init(rawValue: RoutingHostRouter.workspaceID),
        macDeviceID: secondaryMacID,
        name: "Target",
        terminals: [
            MobileTerminalPreview(id: .init(rawValue: RoutingHostRouter.terminalA), name: "A"),
            MobileTerminalPreview(id: .init(rawValue: RoutingHostRouter.terminalB), name: "B"),
        ],
        selectedTerminalID: .init(rawValue: RoutingHostRouter.terminalB)
    )
    store.setWorkspaceStatesForTesting(
        [
            "test-mac": MacWorkspaceState(
                macDeviceID: "test-mac",
                displayName: "Foreground Mac",
                workspaces: [foregroundWorkspace],
                status: .connected
            ),
            secondaryMacID: MacWorkspaceState(
                macDeviceID: secondaryMacID,
                displayName: "Secondary Mac",
                workspaces: [siblingWorkspace, targetWorkspace],
                status: .connected
            ),
        ],
        foregroundMacDeviceID: "test-mac"
    )
    let siblingFocusEvent = try #require(MobileWorkspaceFocusEvent(payloadJSON: Data("""
    {"kind":"focus","workspace_id":"secondary-sibling","focused_pane_id":"sibling-pane","selected_terminal_id":"sibling-b"}
    """.utf8)))
    store.applyWorkspaceFocusEvent(siblingFocusEvent, macID: secondaryMacID)
    let siblingFocusRevision = try #require(
        store.workspaceFocusEventRevisionsByMac[secondaryMacID]?[siblingWorkspace.id.rawValue]
    )
    let targetRowID = try #require(store.workspaces.first(where: {
        $0.macDeviceID == secondaryMacID
            && $0.rpcWorkspaceID.rawValue == RoutingHostRouter.workspaceID
    })?.id)

    let result = await withCheckedContinuation { continuation in
        store.createTerminal(in: targetRowID) { result in
            continuation.resume(returning: result)
        }
    }

    guard case .success = result else {
        Issue.record("Expected secondary terminal creation to succeed, got \(result)")
        return
    }
    let secondaryState = try #require(store.workspacesByMac[secondaryMacID])
    #expect(secondaryState.workspaces.map(\.rpcWorkspaceID.rawValue) == [
        siblingWorkspace.id.rawValue,
        RoutingHostRouter.workspaceID,
    ])
    let siblingAfter = try #require(secondaryState.workspaces.first)
    #expect(siblingAfter.name == "Sibling")
    #expect(siblingAfter.terminals.map(\.id.rawValue) == ["sibling-a", "sibling-b"])
    #expect(siblingAfter.selectedTerminalID == "sibling-b")
    #expect(siblingAfter.terminals.first(where: { $0.id == "sibling-b" })?.isFocused == true)
    #expect(
        store.workspaceFocusEventRevisionsByMac[secondaryMacID]?[siblingWorkspace.id.rawValue]
            == siblingFocusRevision
    )
    #expect(
        secondaryState.workspaces.last?.terminals.map(\.id.rawValue)
            == [RoutingHostRouter.terminalA, RoutingHostRouter.terminalB, "terminal-route-created"]
    )
}
