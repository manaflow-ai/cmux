import Foundation
import Testing
import CmuxSettings
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
    var focusedPanelId: UUID?
    var panelTitles: [UUID: String] = [:]
    func updatePanelTitle(panelId: UUID, title: String) -> Bool { false }
    func applyProcessTitle(_ title: String) {}
    // This fake never participates in panel-id resolution.
    func panelExists(_ panelId: UUID) -> Bool { false }
    func panelId(forSurfaceId surfaceId: UUID) -> UUID? { nil }
}

/// Records the strings the coordinator asks for so the plan assembly can be
/// asserted without the app bundle's real localized catalog, and records every
/// presented ``CloseConfirmationPrompt`` so the decision flow can be asserted
/// without AppKit.
@MainActor
private final class StubConfirming: CloseConfirming {
    /// What `present` reports as the user's answer.
    var confirmResult = true
    /// What `present` reports for the suppression checkbox on confirm.
    var suppressionChecked = false
    private(set) var presentedPrompts: [CloseConfirmationPrompt] = []

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
    var closeWorkspaceTitle: String { "WS_TITLE" }
    var closeWorkspaceMessage: String { "WS_MSG" }
    var closePinnedWorkspaceTitle: String { "PINNED_TITLE" }
    var closePinnedWorkspaceMessage: String { "PINNED_MSG" }
    var closeAnchorTitle: String { "ANCHOR_TITLE" }
    var closeAnchorMessageLoneFormat: String { "LONE|%@" }
    var closeAnchorMessageOneFormat: String { "ONE|%@" }
    var closeAnchorMessageManyFormat: String { "MANY|%1$@|%2$lld" }

    func present(_ prompt: CloseConfirmationPrompt) -> CloseConfirmationOutcome {
        presentedPrompts.append(prompt)
        return CloseConfirmationOutcome(
            confirmed: confirmResult,
            suppressionChecked: confirmResult && suppressionChecked
        )
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
    /// Workspace ids that report needing a confirm-close prompt.
    var needsConfirmIds: Set<UUID> = []
    /// What `closeWindow` reports (true = a window-close was dispatched).
    var closeWindowResult = true

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
    func needsConfirmClose(_ tab: StubTab) -> Bool { needsConfirmIds.contains(tab.id) }
    func markRemoteTmuxKillOnWindowClose() { events.append("markRemoteKill") }
    @discardableResult
    func closeWindow(containingWorkspaceId workspaceId: UUID) -> Bool {
        events.append("closeWindow")
        return closeWindowResult
    }

    // Child-exit-path effects.
    var keepsPersistentRemoteIds: Set<UUID> = []
    var demoteAfterChildExitIds: Set<UUID> = []
    var panelCounts: [UUID: Int] = [:]
    func keepsPersistentRemoteSurfaceOpenAfterChildExit(_ tab: StubTab, surfaceId: UUID) -> Bool {
        keepsPersistentRemoteIds.contains(tab.id)
    }
    func shouldDemoteWorkspaceAfterChildExit(_ tab: StubTab, surfaceId: UUID) -> Bool {
        demoteAfterChildExitIds.contains(tab.id)
    }
    func panelCount(_ tab: StubTab) -> Int { panelCounts[tab.id] ?? 1 }
    func markRemoteTerminalSessionEnded(_ tab: StubTab, surfaceId: UUID) {
        events.append("markRemoteEnded")
    }
    func markPersistentRemotePTYAttachFailed(_ tab: StubTab, surfaceId: UUID) {
        events.append("markPersistentFailed")
    }
    func closeRuntimeSurface(tabId: UUID, surfaceId: UUID) {
        events.append("closeRuntimeSurface")
    }
    @discardableResult
    func closeWindowForLastChildExit(workspaceId: UUID) -> Bool {
        events.append("closeWindowChildExit")
        return closeWindowResult
    }
    func logChildExitCloseDecision(
        _ tab: StubTab,
        surfaceId: UUID,
        workspaceCount: Int,
        handlesRemoteExitThroughWorkspace: Bool,
        keepsPersistentRemoteSurfaceOpen: Bool
    ) {}
}

/// A scoped, empty `UserDefaults`-backed settings client + catalog for the
/// close coordinator's anchor-suppression flag.
@MainActor
private func makeCloseSettings() -> (UserDefaultsSettingsClient, SettingCatalog) {
    let defaults = UserDefaults(suiteName: "WorkspaceCloseCoordinatorTests-\(UUID().uuidString)")!
    return (UserDefaultsSettingsClient(defaults: defaults), SettingCatalog())
}

@MainActor
private func makeCoordinator(
    tabs: [StubTab],
    selected: UUID? = nil
) -> (WorkspaceCloseCoordinator<StubTab>, StubConfirming) {
    let model = WorkspacesModel<StubTab>()
    model.tabs = tabs
    model.selectedTabId = selected
    let (settings, catalog) = makeCloseSettings()
    let coordinator = WorkspaceCloseCoordinator(model: model, settings: settings, catalog: catalog)
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
    let (settings, catalog) = makeCloseSettings()
    let coordinator = WorkspaceCloseCoordinator(model: model, settings: settings, catalog: catalog)
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
        let (settings, catalog) = makeCloseSettings()
        let coordinator = WorkspaceCloseCoordinator(model: model, settings: settings, catalog: catalog)
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

/// A fixed ``CloseTabWarningReading`` for asserting the confirmation decision
/// without touching `UserDefaults`.
private struct FakeCloseTabWarning: CloseTabWarningReading {
    var warnsBeforeClosingTab: Bool
    var warnsBeforeClosingTabXButton: Bool
    var hidesTabCloseButton: Bool = false
}

@MainActor
@Suite
struct WorkspaceCloseConfirmationDecisionTests {
    private func makeCoordinator(
        closeTabWarning: FakeCloseTabWarning
    ) -> WorkspaceCloseCoordinator<StubTab> {
        let (settings, catalog) = makeCloseSettings()
        let coordinator = WorkspaceCloseCoordinator<StubTab>(
            model: WorkspacesModel<StubTab>(),
            settings: settings,
            catalog: catalog
        )
        coordinator.attach(closeTabWarning: closeTabWarning)
        return coordinator
    }

    @Test
    func workspaceSourceHonorsRequiresConfirmationVerbatim() {
        let coordinator = makeCoordinator(
            closeTabWarning: FakeCloseTabWarning(
                warnsBeforeClosingTab: false,
                warnsBeforeClosingTabXButton: false
            )
        )
        // .workspace ignores the warning toggles entirely.
        #expect(coordinator.shouldConfirmClose(requiresConfirmation: true, source: .workspace) == true)
        #expect(coordinator.shouldConfirmClose(requiresConfirmation: false, source: .workspace) == false)
    }

    @Test
    func tabCloseRoutesThroughShortcutWarning() {
        let warnsOn = makeCoordinator(
            closeTabWarning: FakeCloseTabWarning(
                warnsBeforeClosingTab: true,
                warnsBeforeClosingTabXButton: false
            )
        )
        // .tabClose == .shortcut: warn only when the tab requires it AND the
        // shortcut warning is on.
        #expect(warnsOn.shouldConfirmClose(requiresConfirmation: true, source: .tabClose) == true)
        #expect(warnsOn.shouldConfirmClose(requiresConfirmation: false, source: .tabClose) == false)

        let warnsOff = makeCoordinator(
            closeTabWarning: FakeCloseTabWarning(
                warnsBeforeClosingTab: false,
                warnsBeforeClosingTabXButton: true
            )
        )
        // X-button toggle does not affect the shortcut path.
        #expect(warnsOff.shouldConfirmClose(requiresConfirmation: true, source: .tabClose) == false)
    }

    @Test
    func tabCloseButtonRoutesThroughXButtonWarning() {
        let xOn = makeCoordinator(
            closeTabWarning: FakeCloseTabWarning(
                warnsBeforeClosingTab: false,
                warnsBeforeClosingTabXButton: true
            )
        )
        // .tabCloseButton warns whenever the X-button toggle is on, regardless
        // of requiresConfirmation.
        #expect(xOn.shouldConfirmClose(requiresConfirmation: false, source: .tabCloseButton) == true)

        let bothOff = makeCoordinator(
            closeTabWarning: FakeCloseTabWarning(
                warnsBeforeClosingTab: true,
                warnsBeforeClosingTabXButton: false
            )
        )
        // X off but shortcut on + requiresConfirmation still warns (the OR arm).
        #expect(bothOff.shouldConfirmClose(requiresConfirmation: true, source: .tabCloseButton) == true)
        #expect(bothOff.shouldConfirmClose(requiresConfirmation: false, source: .tabCloseButton) == false)
    }
}

/// Covers the close-confirmation decision flow moved off the per-window
/// `TabManager` god object: the in-flight session re-entrancy, the test-override
/// handler, the anchor-suppression flag read/write + which-message choice, and
/// the pinned-close gate.
@MainActor
@Suite
struct WorkspaceCloseConfirmationFlowTests {
    @Test
    func confirmCloseHandlerOverridesPresentationWhenSet() {
        let (coordinator, confirming) = makeCoordinator(tabs: [])
        coordinator.confirmCloseHandler = { _, _, _ in false }
        #expect(coordinator.confirmClose(title: "T", message: "M", acceptCmdD: false) == false)
        // The handler short-circuits before the witness is asked to present.
        #expect(confirming.presentedPrompts.isEmpty)
    }

    @Test
    func confirmClosePresentsWhenNoHandlerAndReportsConfirmation() {
        let (coordinator, confirming) = makeCoordinator(tabs: [])
        confirming.confirmResult = true
        #expect(coordinator.confirmClose(title: "T", message: "M", acceptCmdD: true) == true)
        #expect(confirming.presentedPrompts.count == 1)
        let prompt = confirming.presentedPrompts[0]
        #expect(prompt.title == "T")
        #expect(prompt.message == "M")
        #expect(prompt.acceptCmdD == true)
        #expect(prompt.showsSuppressionCheckbox == false)
    }

    @Test
    func confirmCloseSelfGatesWhileSessionInFlight() {
        let (coordinator, confirming) = makeCoordinator(tabs: [])
        // Simulate an outer session already up (e.g. the anchor dialog path).
        #expect(coordinator.beginCloseConfirmationSession() == true)
        #expect(coordinator.isCloseConfirmationInFlight == true)
        // A nested confirmClose refuses (returns false) without presenting.
        #expect(coordinator.confirmClose(title: "T", message: "M", acceptCmdD: false) == false)
        #expect(confirming.presentedPrompts.isEmpty)
    }

    @Test
    func confirmAnchorReturnsTrueWhenSuppressedWithoutPresenting() {
        let model = WorkspacesModel<StubTab>()
        let (settings, catalog) = makeCloseSettings()
        settings.set(true, for: catalog.workspaceGroups.anchorCloseSuppressed)
        let coordinator = WorkspaceCloseCoordinator(model: model, settings: settings, catalog: catalog)
        let confirming = StubConfirming()
        coordinator.attach(confirming: confirming)
        #expect(coordinator.confirmAnchorWorkspaceClose(groupName: "G", otherMemberCount: 3) == true)
        #expect(confirming.presentedPrompts.isEmpty)
    }

    @Test
    func confirmAnchorAssemblesMessageVariantsAndShowsSuppressionCheckbox() {
        let (coordinator, confirming) = makeCoordinator(tabs: [])

        _ = coordinator.confirmAnchorWorkspaceClose(groupName: "G", otherMemberCount: 0)
        _ = coordinator.confirmAnchorWorkspaceClose(groupName: "G", otherMemberCount: 1)
        _ = coordinator.confirmAnchorWorkspaceClose(groupName: "G", otherMemberCount: 5)

        #expect(confirming.presentedPrompts.count == 3)
        #expect(confirming.presentedPrompts.allSatisfy { $0.title == "ANCHOR_TITLE" })
        #expect(confirming.presentedPrompts.allSatisfy { $0.showsSuppressionCheckbox })
        #expect(confirming.presentedPrompts.allSatisfy { $0.acceptCmdD == false })
        #expect(confirming.presentedPrompts[0].message == "LONE|G")
        #expect(confirming.presentedPrompts[1].message == "ONE|G")
        #expect(confirming.presentedPrompts[2].message == "MANY|G|5")
    }

    @Test
    func confirmAnchorPersistsSuppressionOnlyWhenCheckedAndConfirmed() {
        let model = WorkspacesModel<StubTab>()
        let (settings, catalog) = makeCloseSettings()
        let coordinator = WorkspaceCloseCoordinator(model: model, settings: settings, catalog: catalog)
        let confirming = StubConfirming()
        coordinator.attach(confirming: confirming)

        // Confirmed but checkbox off → no persistence.
        confirming.confirmResult = true
        confirming.suppressionChecked = false
        #expect(coordinator.confirmAnchorWorkspaceClose(groupName: "G", otherMemberCount: 0) == true)
        #expect(settings.value(for: catalog.workspaceGroups.anchorCloseSuppressed) == false)

        // Confirmed with checkbox on → persists the flag.
        confirming.suppressionChecked = true
        #expect(coordinator.confirmAnchorWorkspaceClose(groupName: "G", otherMemberCount: 0) == true)
        #expect(settings.value(for: catalog.workspaceGroups.anchorCloseSuppressed) == true)
    }

    @Test
    func confirmPinnedSkipsConfirmationWhenNotWarned() {
        let (coordinator, confirming) = makeCoordinator(tabs: [])
        coordinator.attach(closeTabWarning: FakeCloseTabWarning(
            warnsBeforeClosingTab: false,
            warnsBeforeClosingTabXButton: false
        ))
        // .tabClose source with both warnings off → no prompt, allow close.
        #expect(coordinator.confirmPinnedWorkspaceClose(source: .tabClose) == true)
        #expect(confirming.presentedPrompts.isEmpty)
    }

    @Test
    func confirmPinnedPresentsPinnedStringsWhenWarned() {
        let (coordinator, confirming) = makeCoordinator(tabs: [])
        coordinator.attach(closeTabWarning: FakeCloseTabWarning(
            warnsBeforeClosingTab: true,
            warnsBeforeClosingTabXButton: false
        ))
        confirming.confirmResult = true
        #expect(coordinator.confirmPinnedWorkspaceClose(source: .tabClose) == true)
        #expect(confirming.presentedPrompts.count == 1)
        #expect(confirming.presentedPrompts[0].title == "PINNED_TITLE")
        #expect(confirming.presentedPrompts[0].message == "PINNED_MSG")
    }
}

/// A fully wired close coordinator (model + host + confirming + warning) for the
/// moved single/batch close-with-confirmation orchestration.
@MainActor
private func makeWiredCoordinator(
    tabs: [StubTab],
    selected: UUID? = nil,
    warnsBeforeClosingTab: Bool = false
) -> (WorkspaceCloseCoordinator<StubTab>, WorkspacesModel<StubTab>, StubCloseHost, StubConfirming) {
    let model = WorkspacesModel<StubTab>()
    model.tabs = tabs
    model.selectedTabId = selected
    let (settings, catalog) = makeCloseSettings()
    let coordinator = WorkspaceCloseCoordinator(model: model, settings: settings, catalog: catalog)
    let host = StubCloseHost()
    let confirming = StubConfirming()
    coordinator.attach(host: host)
    coordinator.attach(confirming: confirming)
    coordinator.attach(closeTabWarning: FakeCloseTabWarning(
        warnsBeforeClosingTab: warnsBeforeClosingTab,
        warnsBeforeClosingTabXButton: false
    ))
    return (coordinator, model, host, confirming)
}

@MainActor
@Suite
struct WorkspaceCloseOrchestrationTests {
    @Test
    func lastWorkspaceClosesWindowAndMarksRemoteKill() {
        let a = StubTab(title: "a")
        let (coordinator, _, host, _) = makeWiredCoordinator(tabs: [a], selected: a.id)
        host.remoteTmuxMirrorIds = [a.id]
        // .workspace source with requiresConfirmation default true but the tab
        // does not need confirm and .workspace honours that verbatim → no prompt.
        coordinator.closeWorkspaceIfRunningProcess(a)
        #expect(host.events == ["markRemoteKill", "closeWindow"])
    }

    @Test
    func nonLastWorkspaceRoutesThroughCloseWorkspace() {
        let a = StubTab(title: "a")
        let b = StubTab(title: "b")
        let (coordinator, model, host, _) = makeWiredCoordinator(tabs: [a, b], selected: a.id)
        coordinator.closeWorkspaceIfRunningProcess(a)
        // Goes through the full closeWorkspace teardown, not the window-close path.
        #expect(!host.events.contains("closeWindow"))
        #expect(host.events.contains("publishClosed"))
        #expect(model.tabs.map(\.id) == [b.id])
    }

    @Test
    func confirmationCancelAbortsClose() {
        let a = StubTab(title: "a")
        let b = StubTab(title: "b")
        let (coordinator, model, host, confirming) = makeWiredCoordinator(
            tabs: [a, b], selected: a.id, warnsBeforeClosingTab: true
        )
        host.needsConfirmIds = [a.id]
        confirming.confirmResult = false
        coordinator.closeWorkspaceIfRunningProcess(a, source: .tabClose)
        // User cancelled → nothing closed.
        #expect(model.tabs.map(\.id) == [a.id, b.id])
        #expect(!host.events.contains("publishClosed"))
    }

    @Test
    func batchClosingEveryWorkspaceClosesWindowOnce() {
        let a = StubTab(title: "a")
        let b = StubTab(title: "b")
        let (coordinator, _, host, confirming) = makeWiredCoordinator(
            tabs: [a, b], selected: a.id, warnsBeforeClosingTab: true
        )
        confirming.confirmResult = true
        coordinator.closeWorkspacesWithConfirmation([a.id, b.id], allowPinned: true)
        // Whole-window close: one batch confirm, one window-close, no per-tab loop.
        #expect(host.events == ["closeWindow"])
        #expect(confirming.presentedPrompts.count == 1)
    }

    @Test
    func batchSubsetClosesEachNonWindowWorkspace() {
        let a = StubTab(title: "a")
        let b = StubTab(title: "b")
        let c = StubTab(title: "c")
        let (coordinator, model, host, confirming) = makeWiredCoordinator(tabs: [a, b, c], selected: a.id)
        confirming.confirmResult = true
        coordinator.closeWorkspacesWithConfirmation([a.id, b.id], allowPinned: true)
        // Not the whole window → loop closes a and b via closeWorkspace teardown.
        #expect(model.tabs.map(\.id) == [c.id])
        #expect(host.events.filter { $0 == "publishClosed" }.count == 2)
        #expect(!host.events.contains("closeWindow"))
    }
}
