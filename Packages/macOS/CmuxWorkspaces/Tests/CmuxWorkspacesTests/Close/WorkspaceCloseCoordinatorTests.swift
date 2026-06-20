import Foundation
import Testing
@testable import CmuxWorkspaces

@MainActor
private final class StubTab: WorkspaceTabRepresenting {
    let id: UUID
    var groupId: UUID?
    var isPinned: Bool
    var currentDirectory: String
    var title: String

    init(
        id: UUID = UUID(),
        isPinned: Bool = false,
        title: String = ""
    ) {
        self.id = id
        self.isPinned = isPinned
        self.currentDirectory = "/tmp"
        self.title = title
    }

    func updatePanelShellActivityState(panelId: UUID, state: PanelShellActivityState) {}
    func setCustomColor(_ hex: String?) {}
}

/// Records the strings the coordinator asks for so the plan assembly can be
/// asserted without the app bundle's real localized catalog.
@MainActor
private final class StubConfirming: CloseConfirming {
    var confirmResult = true
    private(set) var confirmCalls: [(title: String, message: String, acceptCmdD: Bool)] = []

    func closeWorkspacesTitle(willCloseWindow: Bool) -> String {
        willCloseWindow ? "WINDOW_TITLE" : "WORKSPACES_TITLE"
    }

    func closeWorkspacesMessage(
        willCloseWindow: Bool,
        workspaceCount: Int,
        bulletedTitles: String
    ) -> String {
        "\(willCloseWindow ? "WINDOW" : "WS")|\(workspaceCount)|\(bulletedTitles)"
    }

    var workspaceDisplayTitleFallback: String { "FALLBACK" }

    func confirmClose(title: String, message: String, acceptCmdD: Bool) -> Bool {
        confirmCalls.append((title, message, acceptCmdD))
        return confirmResult
    }
}

/// Records the close/detach/attach teardown effects in invocation order so the
/// coordinator's orchestration can be asserted without the app-target
/// `Workspace`/`AppDelegate` collaborators.
@MainActor
private final class StubCloseHost: WorkspaceCloseHosting {
    typealias Tab = StubTab

    /// Each effect appends a tag; `events` is the observable side-effect order.
    private(set) var events: [String] = []
    var remoteTmuxMirrorIds: Set<UUID> = []
    var restorableIds: Set<UUID> = []

    func recordWorkspaceCloseBreadcrumb(remainingTabCount: Int) {
        events.append("breadcrumb(\(remainingTabCount))")
    }
    func isRemoteTmuxMirror(_ tab: StubTab) -> Bool { remoteTmuxMirrorIds.contains(tab.id) }
    func killRemoteTmuxMirror(_ tab: StubTab) { events.append("killRemoteTmux") }
    func isRestorableInSessionSnapshot(_ tab: StubTab) -> Bool { restorableIds.contains(tab.id) }
    func recordClosedWorkspaceHistory(_ tab: StubTab, index: Int) {
        events.append("history(\(index))")
    }
    func clearWorkspaceGitProbes(workspaceId: UUID) { events.append("clearGit") }
    func clearWorkspacePullRequestTracking(workspaceId: UUID) { events.append("clearPR") }
    func removeFromSidebarSelection(workspaceId: UUID) { events.append("removeSel") }
    func invalidateFocusHistoryTarget(workspaceId: UUID) { events.append("invalFocus") }
    func clearNotifications(workspaceId: UUID) { events.append("clearNotif") }
    func teardownAllPanels(_ tab: StubTab) { events.append("teardownPanels") }
    func teardownRemoteConnection(_ tab: StubTab) { events.append("teardownRemote") }
    func unwireClosedBrowserTracking(_ tab: StubTab) { events.append("unwireBrowser") }
    func wireClosedBrowserTracking(_ tab: StubTab) { events.append("wireBrowser") }
    func removeClosedBrowserPanels(workspaceId: UUID) { events.append("removeBrowserPanels") }
    func clearOwningTabManager(_ tab: StubTab) { events.append("clearOwner") }
    func setOwningTabManager(_ tab: StubTab) { events.append("setOwner") }
    func publishWorkspaceClosed(_ tab: StubTab) { events.append("publishClosed") }
    func clearGroupMembership(_ tab: StubTab) { events.append("clearGroup") }
    func forgetRememberedFocus(workspaceId: UUID) { events.append("forgetFocus") }
    func addReplacementWorkspaceForEmptyWindow() { events.append("addReplacement") }
}

@MainActor
private func makeCoordinator(
    tabs: [StubTab],
    selected: UUID? = nil
) -> (WorkspaceCloseCoordinator<StubTab>, StubConfirming) {
    let model = WorkspacesModel<StubTab>()
    model.tabs = tabs
    model.selectedTabId = selected
    let coordinator = WorkspaceCloseCoordinator(model: model)
    let confirming = StubConfirming()
    coordinator.attach(confirming: confirming)
    return (coordinator, confirming)
}

@MainActor
private func makeExecutionCoordinator(
    tabs: [StubTab],
    selected: UUID? = nil
) -> (WorkspaceCloseCoordinator<StubTab>, WorkspacesModel<StubTab>, StubCloseHost) {
    let model = WorkspacesModel<StubTab>()
    model.tabs = tabs
    model.selectedTabId = selected
    let coordinator = WorkspaceCloseCoordinator(model: model)
    let host = StubCloseHost()
    coordinator.attach(host: host)
    return (coordinator, model, host)
}

@MainActor
@Suite("WorkspaceCloseCoordinator")
struct WorkspaceCloseCoordinatorTests {
    @Test
    func orderedClosableWorkspacesPreservesSidebarOrderAndDropsUnknownAndPinned() {
        let a = StubTab(title: "a")
        let b = StubTab(isPinned: true, title: "b")
        let c = StubTab(title: "c")
        let (coordinator, confirming) = makeCoordinator(tabs: [a, b, c])
        _ = confirming // retain the weakly-held seam for the test's lifetime
        let unknown = UUID()

        // Request order is c,a,unknown,b but result follows sidebar order a,b,c
        // and excludes the pinned b (allowPinned=false) and the unknown id.
        let result = coordinator.orderedClosableWorkspaces(
            [c.id, a.id, unknown, b.id],
            allowPinned: false
        )
        #expect(result.map(\.id) == [a.id, c.id])

        // allowPinned=true keeps the pinned workspace, still in sidebar order.
        let withPinned = coordinator.orderedClosableWorkspaces(
            [c.id, a.id, b.id],
            allowPinned: true
        )
        #expect(withPinned.map(\.id) == [a.id, b.id, c.id])
    }

    @Test
    func orderedSidebarSelectedWorkspaceIdsIntersectsInSidebarOrder() {
        let a = StubTab()
        let b = StubTab()
        let c = StubTab()
        let (coordinator, confirming) = makeCoordinator(tabs: [a, b, c])
        _ = confirming // retain the weakly-held seam for the test's lifetime
        let unknown = UUID()

        let result = coordinator.orderedSidebarSelectedWorkspaceIds(
            sidebarSelectedWorkspaceIds: [c.id, a.id, unknown]
        )
        #expect(result == [a.id, c.id])
    }

    @Test
    func closeWorkspacesPlanWindowVariantWhenClosingEveryWorkspace() {
        let a = StubTab(title: "a")
        let b = StubTab(title: "b")
        let (coordinator, confirming) = makeCoordinator(tabs: [a, b])
        _ = confirming // retain the weakly-held seam for the test's lifetime

        let plan = coordinator.closeWorkspacesPlan(for: [a, b])
        #expect(plan != nil)
        #expect(plan?.willCloseWindow == true)
        #expect(plan?.acceptCmdD == true)
        #expect(plan?.workspaceIds == [a.id, b.id])
        #expect(plan?.title == "WINDOW_TITLE")
        // 2 workspaces, bulleted titles preserve order and the "• " prefix.
        #expect(plan?.message == "WINDOW|2|• a\n• b")
    }

    @Test
    func closeWorkspacesPlanSubsetVariantAndEmptyTitleFallback() {
        let a = StubTab(title: "  spaced  ")
        let b = StubTab(title: "")
        let c = StubTab(title: "c")
        let (coordinator, confirming) = makeCoordinator(tabs: [a, b, c])
        _ = confirming // retain the weakly-held seam for the test's lifetime

        // Close two of three -> not the whole window.
        let plan = coordinator.closeWorkspacesPlan(for: [a, b])
        #expect(plan?.willCloseWindow == false)
        #expect(plan?.acceptCmdD == false)
        #expect(plan?.title == "WORKSPACES_TITLE")
        // a's title is whitespace-collapsed; b's empty title becomes FALLBACK.
        #expect(plan?.message == "WS|2|• spaced\n• FALLBACK")
    }

    @Test
    func closeWorkspaceDisplayTitleCollapsesNewlinesAndUsesFallback() {
        let (coordinator, confirming) = makeCoordinator(tabs: [])
        _ = confirming // retain the weakly-held seam for the test's lifetime
        #expect(coordinator.closeWorkspaceDisplayTitle("one\ntwo\rthree") == "one two three")
        #expect(coordinator.closeWorkspaceDisplayTitle("   ") == "FALLBACK")
        #expect(coordinator.closeWorkspaceDisplayTitle(nil) == "FALLBACK")
    }

    @Test
    func planIsNilWhenConfirmingNotAttached() {
        let model = WorkspacesModel<StubTab>()
        let a = StubTab(title: "a")
        model.tabs = [a]
        let coordinator = WorkspaceCloseCoordinator(model: model)
        #expect(coordinator.closeWorkspacesPlan(for: [a]) == nil)
    }

    // MARK: - Lifecycle execution

    @Test
    func closeWorkspaceIsNoOpWhenOnlyOneWorkspaceRemains() {
        let a = StubTab(title: "a")
        let (coordinator, model, host) = makeExecutionCoordinator(tabs: [a], selected: a.id)
        coordinator.closeWorkspace(a)
        #expect(model.tabs.map(\.id) == [a.id])
        #expect(host.events.isEmpty)
    }

    @Test
    func closeWorkspaceRunsTeardownInLegacyOrderAndKeepsFocusedIndex() {
        let a = StubTab(title: "a")
        let b = StubTab(title: "b")
        let c = StubTab(title: "c")
        let (coordinator, model, host) = makeExecutionCoordinator(tabs: [a, b, c], selected: b.id)
        host.restorableIds = [b.id]
        host.remoteTmuxMirrorIds = [b.id]

        coordinator.closeWorkspace(b)

        // Removed from tabs; closing the middle (index 1) re-focuses the
        // workspace that shifted up into index 1 (c).
        #expect(model.tabs.map(\.id) == [a.id, c.id])
        #expect(model.selectedTabId == c.id)
        // Side-effect order is the legacy closeWorkspace sequence.
        #expect(host.events == [
            "breadcrumb(2)",
            "killRemoteTmux",
            "history(1)",
            "clearGit",
            "clearPR",
            "removeSel",
            "invalFocus",
            "clearNotif",
            "teardownPanels",
            "teardownRemote",
            "unwireBrowser",
            "removeBrowserPanels",
            "clearOwner",
            "publishClosed",
        ])
    }

    @Test
    func closeWorkspaceSkipsHistoryAndRemoteKillWhenNotApplicable() {
        let a = StubTab(title: "a")
        let b = StubTab(title: "b")
        let (coordinator, _, host) = makeExecutionCoordinator(tabs: [a, b], selected: a.id)
        // a is neither restorable nor a remote-tmux mirror.
        coordinator.closeWorkspace(a)
        #expect(!host.events.contains("history(0)"))
        #expect(!host.events.contains("killRemoteTmux"))
    }

    @Test
    func closeWorkspaceRecordHistoryFalseSkipsHistoryEvenWhenRestorable() {
        let a = StubTab(title: "a")
        let b = StubTab(title: "b")
        let (coordinator, _, host) = makeExecutionCoordinator(tabs: [a, b], selected: a.id)
        host.restorableIds = [a.id]
        coordinator.closeWorkspace(a, recordHistory: false)
        #expect(!host.events.contains(where: { $0.hasPrefix("history(") }))
    }

    @Test
    func detachWorkspaceRemovesAndReturnsAndReselects() {
        let a = StubTab(title: "a")
        let b = StubTab(title: "b")
        let c = StubTab(title: "c")
        let (coordinator, model, host) = makeExecutionCoordinator(tabs: [a, b, c], selected: a.id)

        let removed = coordinator.detachWorkspace(tabId: a.id)
        #expect(removed?.id == a.id)
        #expect(model.tabs.map(\.id) == [b.id, c.id])
        // Detaching the selected workspace (index 0) re-selects index 0 (b).
        #expect(model.selectedTabId == b.id)
        #expect(host.events == [
            "clearGit",
            "removeSel",
            "invalFocus",
            "clearGroup",
            "unwireBrowser",
            "removeBrowserPanels",
            "clearOwner",
            "forgetFocus",
        ])
    }

    @Test
    func detachLastWorkspaceBackfillsEmptyWindow() {
        let a = StubTab(title: "a")
        let (coordinator, model, host) = makeExecutionCoordinator(tabs: [a], selected: a.id)
        let removed = coordinator.detachWorkspace(tabId: a.id)
        #expect(removed?.id == a.id)
        #expect(model.tabs.isEmpty)
        #expect(host.events.last == "addReplacement")
    }

    @Test
    func detachUnknownIdReturnsNil() {
        let a = StubTab(title: "a")
        let (coordinator, _, host) = makeExecutionCoordinator(tabs: [a], selected: a.id)
        #expect(coordinator.detachWorkspace(tabId: UUID()) == nil)
        #expect(host.events.isEmpty)
    }

    @Test
    func attachWorkspaceInsertsAtIndexWiresTrackingAndSelects() {
        let a = StubTab(title: "a")
        let b = StubTab(title: "b")
        let incoming = StubTab(title: "incoming")
        let (coordinator, model, host) = makeExecutionCoordinator(tabs: [a, b], selected: a.id)

        coordinator.attachWorkspace(incoming, at: 1, select: true)
        #expect(model.tabs.map(\.id) == [a.id, incoming.id, b.id])
        #expect(model.selectedTabId == incoming.id)
        #expect(host.events == ["setOwner", "wireBrowser"])
    }

    @Test
    func attachWorkspaceAppendsWhenIndexNilAndCanSkipSelection() {
        let a = StubTab(title: "a")
        let incoming = StubTab(title: "incoming")
        let (coordinator, model, host) = makeExecutionCoordinator(tabs: [a], selected: a.id)
        _ = host // retain the weakly-held host for the test's lifetime
        coordinator.attachWorkspace(incoming, at: nil, select: false)
        #expect(model.tabs.map(\.id) == [a.id, incoming.id])
        #expect(model.selectedTabId == a.id)
    }
}
