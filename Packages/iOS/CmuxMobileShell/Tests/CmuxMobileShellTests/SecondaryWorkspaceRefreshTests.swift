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
@Test func newerWorkspaceFocusEventSurvivesOlderForegroundListResponse() async throws {
    let router = RoutingHostRouter()
    let store = try await makeRoutingConnectedStore(router: router)
    store.setWorkspaceStatesForTesting(
        [
            "test-mac": MacWorkspaceState(
                macDeviceID: "test-mac",
                workspaces: store.workspaces
            ),
        ],
        foregroundMacDeviceID: "test-mac"
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
