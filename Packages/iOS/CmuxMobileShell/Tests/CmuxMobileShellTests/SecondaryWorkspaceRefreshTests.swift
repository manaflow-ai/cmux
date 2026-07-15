import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func failedSecondaryFetchIsNotAnAuthoritativeMutationRefresh() async throws {
    let store = MobileShellComposite.preview()
    let router = RoutingHostRouter()
    let macID = "secondary-refresh"
    try installSecondaryClient(on: store, macDeviceID: macID, router: router)
    await router.setRejectWorkspaceList(true)
    let subscription = try #require(store.secondaryMacSubscriptions[macID])
    let target = WorkspaceMutationTarget(
        client: subscription.client,
        isForeground: false,
        macDeviceID: macID
    )

    let refreshed = await store.refreshAfterWorkspaceMutation(target)

    #expect(!refreshed)
    #expect(subscription.refreshCompletedGeneration == 0)
}

@MainActor
@Test func failedForegroundFetchIsNotAnAuthoritativeMutationRefresh() async throws {
    let router = RoutingHostRouter()
    let store = MobileShellComposite(
        connectionState: .connected,
        workspaces: MobileShellComposite.preview().workspaces
    )
    try installFreshRemoteClient(on: store, router: router)
    await router.setRejectWorkspaceList(true)
    let target = WorkspaceMutationTarget(
        client: store.remoteClient,
        isForeground: true,
        macDeviceID: "test-mac-2"
    )

    let refreshed = await store.refreshAfterWorkspaceMutation(target)

    #expect(!refreshed)
}

@MainActor
@Test func foregroundMutationRefreshSurvivesAnonymousIdentityAdoption() async throws {
    let router = RoutingHostRouter()
    let store = MobileShellComposite(
        connectionState: .connected,
        workspaces: MobileShellComposite.preview().workspaces
    )
    try installFreshRemoteClient(on: store, router: router)
    store.setWorkspaceStatesForTesting(
        [
            MobileShellComposite.foregroundAnonymousKey: MacWorkspaceState(
                macDeviceID: MobileShellComposite.foregroundAnonymousKey,
                workspaces: store.workspaces
            ),
        ],
        foregroundMacDeviceID: nil
    )
    let workspaceID = try #require(store.workspaces.first?.id)
    let target = WorkspaceMutationTarget(
        client: store.remoteClient,
        isForeground: true,
        macDeviceID: nil
    )
    store.terminalReorderGate.requireRefresh(workspaceID: workspaceID)

    store.adoptForegroundMacIdentity("test-mac-2")
    let refreshed = await store.refreshAfterWorkspaceMutation(target)

    #expect(refreshed)
    #expect(await router.workspaceListGate.requestCount() == 1)
    #expect(store.terminalReorderGate.canMutate(workspaceID: workspaceID))
}

@MainActor
@Test func secondaryMutationRefreshRejectsReplacedSubscriptionClient() async throws {
    let originalRouter = RoutingHostRouter()
    let replacementRouter = RoutingHostRouter()
    let store = MobileShellComposite(
        runtime: RoutingTestRuntime(
            transportFactory: RoutingTransportFactory(router: replacementRouter)
        )
    )
    let macID = "secondary-replaced"
    try installSecondaryClient(on: store, macDeviceID: macID, router: originalRouter)
    let originalSubscription = try #require(store.secondaryMacSubscriptions[macID])
    let target = WorkspaceMutationTarget(
        client: originalSubscription.client,
        isForeground: false,
        macDeviceID: macID
    )
    try installSecondaryClient(on: store, macDeviceID: macID, router: replacementRouter)

    let refreshed = await store.refreshAfterWorkspaceMutation(target)

    #expect(!refreshed)
    #expect(await originalRouter.workspaceListGate.requestCount() == 0)
    #expect(await replacementRouter.workspaceListGate.requestCount() == 0)
}

@MainActor
@Test func foregroundMutationRefreshStartsAfterOlderPullCompletes() async throws {
    let router = RoutingHostRouter()
    let store = MobileShellComposite(
        connectionState: .connected,
        workspaces: MobileShellComposite.preview().workspaces
    )
    try installFreshRemoteClient(on: store, router: router)
    await router.workspaceListGate.setHoldFirst(true)
    let olderPull = Task { await store.refreshForegroundWorkspaceList() }
    await router.workspaceListGate.waitUntilFirstReached()

    let mutationRefresh = Task { await store.refreshForegroundWorkspaceListAfterMutation() }
    await router.workspaceListGate.releaseFirst()

    #expect(!(await olderPull.value))
    #expect(await mutationRefresh.value)
    #expect(await router.workspaceListGate.requestCount() == 2)
}

@MainActor
@Test func cancelledPullCompletionCannotEraseReconnectSuccessor() async throws {
    let router = RoutingHostRouter()
    let store = MobileShellComposite(
        connectionState: .connected,
        workspaces: MobileShellComposite.preview().workspaces
    )
    try installFreshRemoteClient(on: store, router: router)
    await router.workspaceListGate.setHoldFirst(true)
    await router.workspaceListGate.setHoldSecond(true)

    let cancelledPull = Task { await store.refreshForegroundWorkspaceList() }
    await router.workspaceListGate.waitUntilFirstReached()
    store.pullToRefreshTask?.cancel()
    store.pullToRefreshTask = nil

    let successorPull = Task { await store.refreshForegroundWorkspaceList() }
    await router.workspaceListGate.waitUntilSecondReached()
    await router.workspaceListGate.releaseFirst()
    _ = await cancelledPull.value

    #expect(store.pullToRefreshTask != nil)
    let mutationRefresh = Task { await store.refreshForegroundWorkspaceListAfterMutation() }
    for _ in 0..<100 {
        await Task.yield()
    }
    #expect(await router.workspaceListGate.requestCount() == 2)

    await router.workspaceListGate.releaseSecond()
    _ = await successorPull.value
    #expect(await mutationRefresh.value)
    #expect(await router.workspaceListGate.requestCount() == 3)
    #expect(store.pullToRefreshTask == nil)
}

@MainActor
@Test func foregroundMutationRefreshRejectsOlderEventResponse() async throws {
    let router = RoutingHostRouter()
    let store = MobileShellComposite(
        connectionState: .connected,
        workspaces: MobileShellComposite.preview().workspaces
    )
    try installFreshRemoteClient(on: store, router: router)
    await router.workspaceListGate.setHoldFirst(true)
    await router.workspaceListGate.setUsesOrdinalTitles(true)
    let olderEventRefresh = try #require(store.scheduleWorkspaceListRefreshFromEvent())
    await router.workspaceListGate.waitUntilFirstReached()

    let mutationRefresh = await store.refreshForegroundWorkspaceListAfterMutation()
    await router.workspaceListGate.releaseFirst()
    await olderEventRefresh.value

    #expect(mutationRefresh)
    #expect(await router.workspaceListGate.requestCount() == 2)
    #expect(store.workspaces.first?.name == "Fresh Workspace")
}

@MainActor
@Test func successfulForegroundRefreshReopensHierarchyForRemovedWorkspace() async throws {
    let router = RoutingHostRouter()
    let store = MobileShellComposite(
        connectionState: .connected,
        workspaces: MobileShellComposite.preview().workspaces
    )
    try installFreshRemoteClient(on: store, router: router)
    let removedWorkspaceID = try #require(store.workspaces.first?.id)
    store.terminalReorderGate.requireRefresh(workspaceID: removedWorkspaceID)

    #expect(await store.refreshForegroundWorkspaceList())

    #expect(store.terminalReorderGate.canMutate(workspaceID: removedWorkspaceID))
}

@MainActor
@Test func successfulSecondaryRefreshPrunesRemovedWorkspaceRecovery() throws {
    let store = MobileShellComposite.preview()
    let foreground = MobileWorkspacePreview(
        id: "foreground-workspace",
        macDeviceID: "mac-a",
        name: "Foreground",
        terminals: []
    )
    let secondary = MobileWorkspacePreview(
        id: "secondary-workspace",
        macDeviceID: "mac-b",
        name: "Secondary",
        terminals: []
    )
    store.setWorkspaceStatesForTesting(
        [
            "mac-a": MacWorkspaceState(macDeviceID: "mac-a", workspaces: [foreground]),
            "mac-b": MacWorkspaceState(macDeviceID: "mac-b", workspaces: [secondary]),
        ],
        foregroundMacDeviceID: "mac-a"
    )
    let removedWorkspaceID = try #require(
        store.workspaces.first(where: { $0.macDeviceID == "mac-b" })?.id
    )
    store.terminalReorderGate.requireRefresh(workspaceID: removedWorkspaceID)

    store.installAuthoritativeSecondaryWorkspaceState(
        macID: "mac-b",
        displayName: "Secondary Mac",
        workspaces: [],
        actionCapabilities: .none
    )

    #expect(store.terminalReorderGate.canMutate(workspaceID: removedWorkspaceID))
}

@MainActor
@Test func concurrentForegroundMutationRefreshesShareNewestSuccess() async throws {
    let router = RoutingHostRouter()
    let store = MobileShellComposite(
        connectionState: .connected,
        workspaces: MobileShellComposite.preview().workspaces
    )
    try installFreshRemoteClient(on: store, router: router)
    await router.workspaceListGate.setHoldFirst(true)
    let firstRefresh = Task { await store.refreshForegroundWorkspaceListAfterMutation() }
    await router.workspaceListGate.waitUntilFirstReached()

    let secondRefresh = await store.refreshForegroundWorkspaceListAfterMutation()
    await router.workspaceListGate.releaseFirst()

    #expect(secondRefresh)
    #expect(await firstRefresh.value)
    #expect(await router.workspaceListGate.requestCount() == 2)
    #expect(store.foregroundWorkspaceMutationRefreshTask == nil)
}

@MainActor
@Test func foregroundMutationRefreshFollowsReplacementChainToNewestSuccess() async throws {
    let router = RoutingHostRouter()
    let store = MobileShellComposite(
        connectionState: .connected,
        workspaces: MobileShellComposite.preview().workspaces
    )
    try installFreshRemoteClient(on: store, router: router)
    await router.workspaceListGate.setHoldFirst(true)
    await router.workspaceListGate.setHoldSecond(true)
    await router.workspaceListGate.setHoldThird(true)

    let firstRefresh = Task { @MainActor in
        await store.refreshForegroundWorkspaceListAfterMutation()
    }
    await router.workspaceListGate.waitUntilFirstReached()
    let firstInnerRefresh = try #require(store.foregroundWorkspaceMutationRefreshTask)

    let secondRefresh = Task { @MainActor in
        await store.refreshForegroundWorkspaceListAfterMutation()
    }
    await router.workspaceListGate.waitUntilSecondReached()
    let secondInnerRefresh = try #require(store.foregroundWorkspaceMutationRefreshTask)

    await router.workspaceListGate.releaseFirst()
    let firstInnerResult = await firstInnerRefresh.value
    #expect(!firstInnerResult.succeeded)
    await Task { @MainActor in }.value

    let thirdRefresh = Task { @MainActor in
        await store.refreshForegroundWorkspaceListAfterMutation()
    }
    await router.workspaceListGate.waitUntilThirdReached()
    let authoritativeEpoch = store.foregroundWorkspaceListMutationEpoch

    await router.workspaceListGate.releaseSecond()
    let secondInnerResult = await secondInnerRefresh.value
    #expect(!secondInnerResult.succeeded)
    await Task { @MainActor in }.value

    await router.workspaceListGate.releaseThird()
    let results = await (firstRefresh.value, secondRefresh.value, thirdRefresh.value)

    #expect(results.0, "the first caller must not surface a superseded recovery failure")
    #expect(results.1, "the second caller must share the authoritative successor")
    #expect(results.2, "the newest authoritative refresh must succeed")
    #expect(store.foregroundWorkspaceListAppliedMutationEpoch >= authoritativeEpoch)
    #expect(await router.workspaceListGate.requestCount() == 3)
    #expect(store.foregroundWorkspaceMutationRefreshTask == nil)
}

@MainActor
@Test func olderSecondaryAggregationCannotOverwritePostMutationRefresh() async throws {
    let router = RoutingHostRouter()
    await router.workspaceListGate.setHoldFirst(true)
    await router.workspaceListGate.setUsesOrdinalTitles(true)
    let macID = "secondary-generation"
    let route = try CmxAttachRoute(
        id: "debug_loopback_secondary_generation",
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
    try installSecondaryClient(on: store, macDeviceID: macID, router: router)
    let subscription = try #require(store.secondaryMacSubscriptions[macID])
    let target = WorkspaceMutationTarget(
        client: subscription.client,
        isForeground: false,
        macDeviceID: macID
    )

    let olderAggregation = Task { @MainActor in
        await store.refreshSecondaryMacWorkspaces()
    }
    await router.workspaceListGate.waitUntilFirstReached()
    let mutationRefresh = Task { @MainActor in
        await store.refreshAfterWorkspaceMutation(target)
    }
    await router.workspaceListGate.waitUntilRequestCount(2)
    #expect(await mutationRefresh.value)
    let refreshedWorkspaceID = try #require(
        store.workspaces.first(where: { $0.macDeviceID == macID })?.id
    )
    store.terminalReorderGate.requireRefresh(workspaceID: refreshedWorkspaceID)

    await router.workspaceListGate.releaseFirst()
    await olderAggregation.value

    #expect(store.workspaces.first(where: { $0.macDeviceID == macID })?.name == "Fresh Workspace")
    #expect(!store.terminalReorderGate.canMutate(workspaceID: refreshedWorkspaceID))
}

@MainActor
@Test func secondaryCreateInvalidatesFullRefreshSuspendedAfterItsFetch() async throws {
    let router = RoutingHostRouter()
    let macID = "secondary-create-fence"
    let route = try CmxAttachRoute(
        id: "debug_loopback_secondary_create_fence",
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
        blockedTeams: ["team-a"]
    )
    let store = makeRoutingMultiMacStore(router: router, pairedMacStore: pairedMacStore)
    try installSecondaryClient(on: store, macDeviceID: macID, router: router)
    let workspace = MobileWorkspacePreview(
        id: .init(rawValue: RoutingHostRouter.workspaceID),
        macDeviceID: macID,
        name: "Routing Workspace",
        terminals: [
            MobileTerminalPreview(id: .init(rawValue: RoutingHostRouter.terminalA), name: "A"),
            MobileTerminalPreview(id: .init(rawValue: RoutingHostRouter.terminalB), name: "B"),
        ],
        selectedTerminalID: .init(rawValue: RoutingHostRouter.terminalB)
    )
    store.setWorkspaceStatesForTesting(
        [macID: MacWorkspaceState(
            macDeviceID: macID,
            displayName: "Secondary Mac",
            workspaces: [workspace],
            status: .connected
        )],
        foregroundMacDeviceID: "foreground-mac"
    )
    let rowID = try #require(store.workspaces.first?.id)
    let subscription = try #require(store.secondaryMacSubscriptions[macID])

    let olderRefresh = try #require(store.scheduleSecondaryRefresh(
        macID: macID,
        client: subscription.client,
        displayName: "Secondary Mac"
    ))
    // The host has already encoded the pre-create hierarchy. Park the refresh in
    // its post-fetch authority validation, where the old generation guard used to
    // remain unchanged across a successful scoped create.
    await pairedMacStore.waitUntilLoadStarted(teamID: "team-a")

    let createTask = Task { @MainActor in
        await store.createRemoteTerminal(in: rowID)
    }
    for _ in 0..<300 where store.workspaces.first?.terminals.contains(where: {
        $0.id.rawValue == "terminal-route-created"
    }) != true {
        await Task.yield()
    }
    #expect(store.workspaces.first?.terminals.contains(where: {
        $0.id.rawValue == "terminal-route-created"
    }) == true)

    await pairedMacStore.release(teamID: "team-a")
    let createResult = await createTask.value
    guard case .success = createResult else {
        Issue.record("Expected secondary terminal creation to succeed: \(createResult)")
        return
    }
    await olderRefresh.value

    #expect(await router.workspaceListGate.requestCount() == 2)
    #expect(store.workspaces.first?.terminals.contains(where: {
        $0.id.rawValue == "terminal-route-created"
    }) == true)
}

@Test func terminalSubscriptionsIncludeScopedWorkspaceFocusTopic() {
    #expect(MobileShellComposite.TerminalOutputTransport.hybrid.eventTopics.contains("workspace.focused"))
    #expect(MobileShellComposite.TerminalOutputTransport.renderGrid.eventTopics.contains("workspace.focused"))
    #expect(MobileShellComposite.TerminalOutputTransport.rawBytes.eventTopics.contains("workspace.focused"))
}

@MainActor
@Test func foregroundMutationRefreshRejectsReplacedClient() async throws {
    let originalRouter = RoutingHostRouter()
    let store = MobileShellComposite(
        connectionState: .connected,
        workspaces: MobileShellComposite.preview().workspaces
    )
    try installFreshRemoteClient(on: store, router: originalRouter)
    let target = WorkspaceMutationTarget(
        client: store.remoteClient,
        isForeground: true,
        macDeviceID: store.foregroundMacDeviceID
    )
    let replacementRouter = RoutingHostRouter()
    try installFreshRemoteClient(on: store, router: replacementRouter)

    let refreshed = await store.refreshAfterWorkspaceMutation(target)

    #expect(!refreshed)
    #expect(await originalRouter.workspaceListGate.requestCount() == 0)
    #expect(await replacementRouter.workspaceListGate.requestCount() == 0)
}

@MainActor
@Test func workspaceFocusEventUpdatesOnlyItsWorkspaceSnapshot() throws {
    let workspace = MobileWorkspacePreview(
        id: "ws-focus",
        name: "Focus",
        terminals: [
            MobileTerminalPreview(id: "terminal-a", name: "A", paneID: "pane-left", isFocused: true),
            MobileTerminalPreview(id: "terminal-b", name: "B", paneID: "pane-right"),
        ],
        panes: [
            MobilePanePreview(id: "pane-left", spatialIndex: 0, isFocused: true, terminalIDs: ["terminal-a"]),
            MobilePanePreview(id: "pane-right", spatialIndex: 1, terminalIDs: ["terminal-b"]),
        ],
        focusedPaneID: "pane-left",
        selectedTerminalID: "terminal-a"
    )
    let store = MobileShellComposite(workspaces: [workspace])
    let event = try #require(MobileWorkspaceFocusEvent(payloadJSON: Data("""
    {"kind":"focus","workspace_id":"ws-focus","focused_pane_id":"pane-right","selected_terminal_id":"terminal-b"}
    """.utf8)))

    store.applyWorkspaceFocusEvent(event, macID: nil)

    let updated = try #require(store.workspaces.first)
    #expect(updated.focusedPaneID == "pane-right")
    #expect(updated.selectedTerminalID == "terminal-b")
    #expect(updated.panes.first(where: { $0.id == "pane-right" })?.isFocused == true)
    #expect(updated.terminals.first(where: { $0.id == "terminal-b" })?.isFocused == true)
}

@MainActor
@Test func newerWorkspaceFocusEventSurvivesOlderForegroundListResponseDuringConnectPromotion() async throws {
    let router = RoutingHostRouter()
    let store = try await makeRoutingConnectedStore(router: router)
    store.setWorkspaceStatesForTesting(
        [
            MobileShellComposite.foregroundAnonymousKey: MacWorkspaceState(
                macDeviceID: MobileShellComposite.foregroundAnonymousKey,
                workspaces: store.workspaces
            ),
        ],
        foregroundMacDeviceID: nil
    )
    await router.workspaceListGate.setHoldFirst(true)
    let refresh = try #require(store.scheduleWorkspaceListRefreshFromEvent())
    await router.workspaceListGate.waitUntilFirstReached()
    let event = try #require(MobileWorkspaceFocusEvent(payloadJSON: Data("""
    {"kind":"focus","workspace_id":"ws-route","focused_pane_id":null,"selected_terminal_id":"term-route-b"}
    """.utf8)))

    store.applyWorkspaceFocusEvent(event, macID: nil)
    await router.workspaceListGate.releaseFirst()
    await refresh.value

    let workspace = try #require(store.workspaces.first(where: { $0.rpcWorkspaceID == "ws-route" }))
    #expect(workspace.selectedTerminalID == "term-route-b")
    #expect(workspace.terminals.first(where: { $0.id == "term-route-b" })?.isFocused == true)
}

@MainActor
@Test func stalePostCloseFocusEventCannotRestoreRemovedTerminal() throws {
    let workspaceID = MobileWorkspacePreview.ID(rawValue: RoutingHostRouter.workspaceID)
    let closingTerminalID = MobileTerminalPreview.ID(rawValue: RoutingHostRouter.terminalA)
    let survivorID = MobileTerminalPreview.ID(rawValue: RoutingHostRouter.terminalB)
    let closingPaneID = MobilePanePreview.ID(rawValue: "pane-left")
    let existingWorkspace = MobileWorkspacePreview(
        id: workspaceID,
        name: "Routing Workspace",
        terminals: [
            MobileTerminalPreview(
                id: closingTerminalID,
                name: "A",
                paneID: closingPaneID,
                isFocused: true
            ),
            MobileTerminalPreview(id: survivorID, name: "B", paneID: "pane-right"),
        ],
        panes: [
            MobilePanePreview(
                id: closingPaneID,
                spatialIndex: 0,
                isFocused: true,
                terminalIDs: [closingTerminalID]
            ),
            MobilePanePreview(
                id: "pane-right",
                spatialIndex: 1,
                terminalIDs: [survivorID]
            ),
        ],
        focusedPaneID: closingPaneID,
        selectedTerminalID: closingTerminalID
    )
    let store = MobileShellComposite(workspaces: [existingWorkspace])
    store.selectedWorkspaceID = workspaceID
    store.selectTerminal(closingTerminalID)
    let listStartedAtFocusRevision = store.workspaceFocusRevisionSnapshot()
    let staleEvent = try #require(MobileWorkspaceFocusEvent(payloadJSON: Data("""
    {"kind":"focus","workspace_id":"ws-route","focused_pane_id":"pane-left","selected_terminal_id":"term-route-a"}
    """.utf8)))
    store.applyWorkspaceFocusEvent(staleEvent, macID: nil)
    let staleWorkspace = try #require(store.workspaces.first)
    var refreshed = MobileWorkspacePreview(
        id: workspaceID,
        name: "Routing Workspace",
        terminals: [
            MobileTerminalPreview(
                id: survivorID,
                name: "B",
                paneID: "pane-right",
                isFocused: true
            ),
        ],
        panes: [
            MobilePanePreview(
                id: "pane-right",
                spatialIndex: 0,
                isFocused: true,
                terminalIDs: [survivorID]
            ),
        ],
        focusedPaneID: "pane-right",
        selectedTerminalID: survivorID
    )
    store.preserveNewerWorkspaceFocusIfNeeded(
        in: &refreshed,
        from: staleWorkspace,
        macID: nil,
        listStartedAtFocusRevision: listStartedAtFocusRevision
    )
    store.replaceForegroundWorkspaceState([refreshed])
    let merged = try #require(store.workspaces.first)
    let fallback = MobileTerminalCloseFallback(
        closedTerminalID: closingTerminalID,
        selectedTerminalID: closingTerminalID,
        orderedTerminalIDs: [closingTerminalID]
    )
    store.selectTerminal(
        fallback.resolvedSelection(
            availableTerminalIDs: Set(merged.terminals.map(\.id))
        ) ?? merged.selectedTerminalID ?? merged.terminals.first?.id
    )

    #expect(merged.terminals.map(\.id) == [survivorID])
    #expect(merged.focusedPaneID == "pane-right")
    #expect(merged.selectedTerminalID == survivorID)
    #expect(merged.panes.first?.isFocused == true)
    #expect(merged.terminals.first?.isFocused == true)
    #expect(store.selectedTerminalID == survivorID)
}
