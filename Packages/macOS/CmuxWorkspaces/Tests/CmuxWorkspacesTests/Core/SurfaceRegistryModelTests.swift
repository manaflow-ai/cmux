import Combine
import Foundation
import Bonsplit
import Testing
@testable import CmuxWorkspaces

@MainActor
@Suite("SurfaceRegistryModel")
struct SurfaceRegistryModelTests {
    private struct StubRequest: Equatable {
        let token: Int
    }

    @Test("starts empty, matching the legacy stored-property defaults")
    func initialState() {
        let model = SurfaceRegistryModel<StubRequest>()
        #expect(model.pendingTabSelection == nil)
        #expect(model.isApplyingTabSelection == false)
        #expect(model.pendingNonFocusSplitFocusReassert == nil)
        #expect(model.nonFocusSplitFocusReassertGeneration == 0)
        #expect(model.surfaceTTYNames.isEmpty)
        #expect(model.panelShellActivityStates.isEmpty)
        #expect(model.panelDirectories.isEmpty)
        #expect(model.panelTitles.isEmpty)
        #expect(model.panelCustomTitles.isEmpty)
        #expect(model.surfaceListeningPorts.isEmpty)
    }

    @Test("directory/title/port maps round-trip and support filter-style pruning")
    func directoryTitlePortRoundtrip() {
        let model = SurfaceRegistryModel<StubRequest>()
        let kept = UUID()
        let dropped = UUID()
        model.panelDirectories = [kept: "/a", dropped: "/b"]
        model.panelTitles = [kept: "A", dropped: "B"]
        model.panelCustomTitles = [kept: "Custom"]
        model.surfaceListeningPorts = [kept: [3000, 8080], dropped: [9000]]

        let valid: Set<UUID> = [kept]
        model.panelDirectories = model.panelDirectories.filter { valid.contains($0.key) }
        model.panelTitles = model.panelTitles.filter { valid.contains($0.key) }
        model.surfaceListeningPorts = model.surfaceListeningPorts.filter { valid.contains($0.key) }

        #expect(model.panelDirectories == [kept: "/a"])
        #expect(model.panelTitles == [kept: "A"])
        #expect(model.panelCustomTitles == [kept: "Custom"])
        #expect(model.surfaceListeningPorts == [kept: [3000, 8080]])
    }

    @Test("directory/title publishers replay current value then emit every assignment")
    func publisherObserverParity() {
        let model = SurfaceRegistryModel<StubRequest>()
        let panel = UUID()
        model.panelDirectories = [panel: "/seed"]

        var directorySnapshots: [[UUID: String]] = []
        var titleSnapshots: [[UUID: String]] = []
        var customSnapshots: [[UUID: String]] = []
        var cancellables = Set<AnyCancellable>()

        // Replay-on-subscribe: each subject emits its current value immediately,
        // matching the @Published projection the legacy subscribers relied on.
        model.panelDirectoriesPublisher.sink { directorySnapshots.append($0) }.store(in: &cancellables)
        model.panelTitlesPublisher.sink { titleSnapshots.append($0) }.store(in: &cancellables)
        model.panelCustomTitlesPublisher.sink { customSnapshots.append($0) }.store(in: &cancellables)

        #expect(directorySnapshots == [[panel: "/seed"]])
        #expect(titleSnapshots == [[:]])
        #expect(customSnapshots == [[:]])

        model.panelDirectories[panel] = "/changed"
        model.panelTitles[panel] = "Title"
        model.panelCustomTitles[panel] = "Custom"
        // Send-on-equal-assignment parity: re-assigning the same value still emits,
        // exactly as @Published did.
        model.panelTitles[panel] = "Title"

        #expect(directorySnapshots == [[panel: "/seed"], [panel: "/changed"]])
        #expect(titleSnapshots == [[:], [panel: "Title"], [panel: "Title"]])
        #expect(customSnapshots == [[:], [panel: "Custom"]])
    }

    @Test("stores and drains a pending tab-selection request")
    func pendingTabSelectionRoundtrip() {
        let model = SurfaceRegistryModel<StubRequest>()
        model.pendingTabSelection = StubRequest(token: 7)
        model.isApplyingTabSelection = true
        #expect(model.pendingTabSelection == StubRequest(token: 7))
        model.pendingTabSelection = nil
        model.isApplyingTabSelection = false
        #expect(model.pendingTabSelection == nil)
        #expect(model.isApplyingTabSelection == false)
    }

    @Test("stores a focus re-assert request alongside its generation")
    func focusReassertRoundtrip() {
        let model = SurfaceRegistryModel<StubRequest>()
        let preferred = UUID()
        let split = UUID()
        model.nonFocusSplitFocusReassertGeneration &+= 1
        let request = PendingNonFocusSplitFocusReassert(
            generation: model.nonFocusSplitFocusReassertGeneration,
            preferredPanelId: preferred,
            splitPanelId: split
        )
        model.pendingNonFocusSplitFocusReassert = request
        #expect(model.pendingNonFocusSplitFocusReassert == request)
        #expect(model.pendingNonFocusSplitFocusReassert?.generation == 1)
        model.pendingNonFocusSplitFocusReassert = nil
        #expect(model.pendingNonFocusSplitFocusReassert == nil)
    }

    @Test("registry maps support the workspace's filter-style pruning")
    func registryMapPruning() {
        let model = SurfaceRegistryModel<StubRequest>()
        let kept = UUID()
        let dropped = UUID()
        model.surfaceTTYNames = [kept: "/dev/ttys001", dropped: "/dev/ttys002"]
        model.panelShellActivityStates = [kept: .commandRunning, dropped: .promptIdle]

        let valid: Set<UUID> = [kept]
        model.surfaceTTYNames = model.surfaceTTYNames.filter { valid.contains($0.key) }
        model.panelShellActivityStates = model.panelShellActivityStates.filter { valid.contains($0.key) }

        #expect(model.surfaceTTYNames == [kept: "/dev/ttys001"])
        #expect(model.panelShellActivityStates == [kept: .commandRunning])
    }
}

/// A minimal in-memory ``SurfaceRegistryHosting`` modeling a single pane of
/// bonsplit tabs plus the panel-id ↔ surface-id mapping and per-panel
/// display-title / kind, so the lifted title/pin/kind logic can be exercised
/// without the app target.
@MainActor
private final class FakeSurfaceRegistryHost: SurfaceRegistryHosting {
    let paneId = PaneID()
    var tabs: [Bonsplit.Tab] = []
    var panelToSurface: [UUID: TabID] = [:]
    var displayTitles: [UUID: String] = [:]
    var kinds: [UUID: String] = [:]
    var isRemoteTmuxMirror = false
    var mirrorRenames: [(panelId: UUID, title: String)] = []
    var workspaceCustomTitle: String?
    var workspaceTitle = ""
    var workspaceProcessTitle = ""
    var updatePanelTitleLogs: [(panelId: UUID, trimmedTitle: String, panelCount: Int, hasCustomTitle: Bool, didMutatePanelTitle: Bool, didMutateWorkspaceTitle: Bool)] = []

    func register(panelId: UUID, displayTitle: String, kind: String, tab: Bonsplit.Tab) {
        panelToSurface[panelId] = tab.id
        displayTitles[panelId] = displayTitle
        kinds[panelId] = kind
        tabs.append(tab)
    }

    private func surfaceToPanel(_ surfaceId: TabID) -> UUID? {
        panelToSurface.first(where: { $0.value == surfaceId })?.key
    }

    private func updateTab(_ tabId: TabID, _ transform: (Bonsplit.Tab) -> Bonsplit.Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabs[index] = transform(tabs[index])
    }

    func surfaceRegistryPanelExists(_ panelId: UUID) -> Bool { displayTitles[panelId] != nil }
    func surfaceRegistryPanelDisplayTitle(panelId: UUID) -> String? { displayTitles[panelId] }
    func surfaceRegistryPanelKind(panelId: UUID) -> String? { kinds[panelId] }
    func surfaceRegistrySurfaceId(forPanelId panelId: UUID) -> TabID? { panelToSurface[panelId] }
    func surfaceRegistryPanelId(forSurfaceId surfaceId: TabID) -> UUID? { surfaceToPanel(surfaceId) }
    func surfaceRegistryPaneId(forPanelId panelId: UUID) -> PaneID? {
        panelToSurface[panelId] == nil ? nil : paneId
    }
    func surfaceRegistryTab(_ tabId: TabID) -> Bonsplit.Tab? { tabs.first(where: { $0.id == tabId }) }
    func surfaceRegistryTabs(inPane paneId: PaneID) -> [Bonsplit.Tab] {
        paneId == self.paneId ? tabs : []
    }
    func surfaceRegistryReorderTab(_ tabId: TabID, toIndex index: Int) -> Bool {
        guard let from = tabs.firstIndex(where: { $0.id == tabId }), index >= 0, index < tabs.count else { return false }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: index)
        return true
    }
    func surfaceRegistryUpdateTab(_ tabId: TabID, title: String, hasCustomTitle: Bool) {
        updateTab(tabId) { tab in
            Bonsplit.Tab(id: tab.id, title: title, hasCustomTitle: hasCustomTitle, kind: tab.kind, isPinned: tab.isPinned)
        }
    }
    func surfaceRegistryUpdateTab(_ tabId: TabID, kind: String, isPinned: Bool) {
        updateTab(tabId) { tab in
            Bonsplit.Tab(id: tab.id, title: tab.title, hasCustomTitle: tab.hasCustomTitle, kind: kind, isPinned: isPinned)
        }
    }
    func surfaceRegistryUpdateTab(_ tabId: TabID, isPinned: Bool) {
        updateTab(tabId) { tab in
            Bonsplit.Tab(id: tab.id, title: tab.title, hasCustomTitle: tab.hasCustomTitle, kind: tab.kind, isPinned: isPinned)
        }
    }
    var surfaceRegistryPanelCount: Int { displayTitles.count }
    var surfaceRegistryWorkspaceCustomTitle: String? { workspaceCustomTitle }
    var surfaceRegistryWorkspaceTitle: String {
        get { workspaceTitle }
        set { workspaceTitle = newValue }
    }
    var surfaceRegistryWorkspaceProcessTitle: String {
        get { workspaceProcessTitle }
        set { workspaceProcessTitle = newValue }
    }
    func surfaceRegistryLogUpdatePanelTitle(
        panelId: UUID,
        trimmedTitle: String,
        panelCount: Int,
        hasCustomTitle: Bool,
        didMutatePanelTitle: Bool,
        didMutateWorkspaceTitle: Bool
    ) {
        updatePanelTitleLogs.append((panelId, trimmedTitle, panelCount, hasCustomTitle, didMutatePanelTitle, didMutateWorkspaceTitle))
    }
    var surfaceRegistryIsRemoteTmuxMirror: Bool { isRemoteTmuxMirror }
    func surfaceRegistryHandleMirrorWindowRenamed(panelId: UUID, title: String) {
        mirrorRenames.append((panelId, title))
    }
}

@MainActor
@Suite("SurfaceRegistryModel title / pin / kind")
struct SurfaceRegistryModelPanelAccessTests {
    private struct StubRequest: Equatable { let token: Int }

    private func make() -> (SurfaceRegistryModel<StubRequest>, FakeSurfaceRegistryHost) {
        let model = SurfaceRegistryModel<StubRequest>()
        let host = FakeSurfaceRegistryHost()
        model.attach(host: host)
        return (model, host)
    }

    @Test("resolvedPanelTitle prefers a non-empty custom title, else trimmed fallback, else Tab")
    func resolvedPanelTitleTiers() {
        let (model, _) = make()
        let panel = UUID()
        #expect(model.resolvedPanelTitle(panelId: panel, fallback: "  ") == "Tab")
        #expect(model.resolvedPanelTitle(panelId: panel, fallback: "  zsh ") == "zsh")
        model.panelCustomTitles[panel] = "  Custom  "
        #expect(model.resolvedPanelTitle(panelId: panel, fallback: "zsh") == "Custom")
        model.panelCustomTitles[panel] = "   "
        #expect(model.resolvedPanelTitle(panelId: panel, fallback: "zsh") == "zsh")
    }

    @Test("setPanelCustomTitle: user write lands, updates the tab, and claims ownership over later auto")
    func setCustomTitleUserThenAuto() {
        let (model, host) = make()
        let panel = UUID()
        host.register(panelId: panel, displayTitle: "zsh", kind: "terminal",
                      tab: Bonsplit.Tab(id: TabID(), title: "zsh", kind: "terminal"))

        #expect(model.setPanelCustomTitle(panelId: panel, title: "Mine") == true)
        #expect(model.panelCustomTitles[panel] == "Mine")
        #expect(model.panelCustomTitleSources[panel] == .user)
        #expect(host.tabs[0].title == "Mine")
        #expect(host.tabs[0].hasCustomTitle == true)

        // .auto cannot overwrite a user title.
        #expect(model.setPanelCustomTitle(panelId: panel, title: "Bot", source: .auto) == false)
        #expect(model.panelCustomTitles[panel] == "Mine")
    }

    @Test("setPanelCustomTitle: absent panel rejected; empty clears only when present")
    func setCustomTitleEdgeCases() {
        let (model, host) = make()
        let absent = UUID()
        #expect(model.setPanelCustomTitle(panelId: absent, title: "X") == false)

        let panel = UUID()
        host.register(panelId: panel, displayTitle: "zsh", kind: "terminal",
                      tab: Bonsplit.Tab(id: TabID(), title: "zsh", kind: "terminal"))
        #expect(model.setPanelCustomTitle(panelId: panel, title: "") == false)
        model.setPanelCustomTitle(panelId: panel, title: "Set")
        #expect(model.setPanelCustomTitle(panelId: panel, title: nil) == true)
        #expect(model.panelCustomTitles[panel] == nil)
        #expect(model.panelCustomTitleSources[panel] == nil)
    }

    @Test("setPanelCustomTitle on a remote tmux mirror propagates the rename")
    func setCustomTitleMirrorRename() {
        let (model, host) = make()
        host.isRemoteTmuxMirror = true
        let panel = UUID()
        host.register(panelId: panel, displayTitle: "zsh", kind: "terminal",
                      tab: Bonsplit.Tab(id: TabID(), title: "zsh", kind: "terminal"))
        model.setPanelCustomTitle(panelId: panel, title: "Remote")
        #expect(host.mirrorRenames.count == 1)
        #expect(host.mirrorRenames.first?.panelId == panel)
        #expect(host.mirrorRenames.first?.title == "Remote")
    }

    @Test("panelTitle resolves through the host; absent panel returns nil")
    func panelTitleResolution() {
        let (model, host) = make()
        let panel = UUID()
        host.register(panelId: panel, displayTitle: "zsh", kind: "terminal",
                      tab: Bonsplit.Tab(id: TabID(), title: "zsh", kind: "terminal"))
        #expect(model.panelTitle(panelId: panel) == "zsh")
        model.panelTitles[panel] = "auto-title"
        #expect(model.panelTitle(panelId: panel) == "auto-title")
        model.panelCustomTitles[panel] = "Custom"
        #expect(model.panelTitle(panelId: panel) == "Custom")
        #expect(model.panelTitle(panelId: UUID()) == nil)
    }

    @Test("updatePanelTitle: empty/whitespace rejected; sets panel title and projects the tab once")
    func updatePanelTitleProjectsTab() {
        let (model, host) = make()
        let panel = UUID()
        host.register(panelId: panel, displayTitle: "zsh", kind: "terminal",
                      tab: Bonsplit.Tab(id: TabID(), title: "zsh", kind: "terminal"))
        // Two panels so the single-panel workspace-title promotion is gated off.
        host.displayTitles[UUID()] = "other"

        #expect(model.updatePanelTitle(panelId: panel, title: "   ") == false)
        #expect(model.panelTitles[panel] == nil)

        #expect(model.updatePanelTitle(panelId: panel, title: "  vim  ") == true)
        #expect(model.panelTitles[panel] == "vim")
        #expect(host.tabs[0].title == "vim")
        #expect(host.tabs[0].hasCustomTitle == false)

        // No change on a repeat write.
        #expect(model.updatePanelTitle(panelId: panel, title: "vim") == false)
    }

    @Test("updatePanelTitle: a custom title masks the resolved tab title but the auto title still records")
    func updatePanelTitleWithCustom() {
        let (model, host) = make()
        let panel = UUID()
        host.register(panelId: panel, displayTitle: "zsh", kind: "terminal",
                      tab: Bonsplit.Tab(id: TabID(), title: "zsh", kind: "terminal"))
        host.displayTitles[UUID()] = "other"
        model.panelCustomTitles[panel] = "Custom"

        #expect(model.updatePanelTitle(panelId: panel, title: "vim") == true)
        #expect(model.panelTitles[panel] == "vim")
        #expect(host.tabs[0].title == "Custom")
        #expect(host.tabs[0].hasCustomTitle == true)
    }

    @Test("updatePanelTitle: single panel with no custom title promotes to workspace title and process title")
    func updatePanelTitlePromotesWorkspaceTitle() {
        let (model, host) = make()
        let panel = UUID()
        host.register(panelId: panel, displayTitle: "zsh", kind: "terminal",
                      tab: Bonsplit.Tab(id: TabID(), title: "zsh", kind: "terminal"))
        host.workspaceTitle = "old"
        host.workspaceProcessTitle = "old"

        #expect(model.updatePanelTitle(panelId: panel, title: "vim") == true)
        #expect(host.workspaceTitle == "vim")
        #expect(host.workspaceProcessTitle == "vim")

        // A workspace custom title blocks promotion.
        host.workspaceCustomTitle = "Pinned"
        host.workspaceTitle = "old2"
        #expect(model.updatePanelTitle(panelId: panel, title: "emacs") == true)
        #expect(host.workspaceTitle == "old2")
    }

    @Test("updatePanelTitle: logs only on a mutating write, with the resolved flags")
    func updatePanelTitleLogs() {
        let (model, host) = make()
        let panel = UUID()
        host.register(panelId: panel, displayTitle: "zsh", kind: "terminal",
                      tab: Bonsplit.Tab(id: TabID(), title: "zsh", kind: "terminal"))

        #expect(model.updatePanelTitle(panelId: panel, title: "vim") == true)
        #expect(host.updatePanelTitleLogs.count == 1)
        #expect(host.updatePanelTitleLogs[0].didMutatePanelTitle == true)
        #expect(host.updatePanelTitleLogs[0].didMutateWorkspaceTitle == true)

        // A no-op repeat does not log.
        #expect(model.updatePanelTitle(panelId: panel, title: "vim") == false)
        #expect(host.updatePanelTitleLogs.count == 1)
    }

    @Test("panelKind forwards the host projection")
    func panelKindForwards() {
        let (model, host) = make()
        let panel = UUID()
        host.register(panelId: panel, displayTitle: "x", kind: "browser",
                      tab: Bonsplit.Tab(id: TabID(), title: "x", kind: "browser"))
        #expect(model.panelKind(panelId: panel) == "browser")
        #expect(model.panelKind(panelId: UUID()) == nil)
    }

    @Test("setPanelPinned toggles the set, updates the tab, and is a no-op on repeat")
    func setPinned() {
        let (model, host) = make()
        let panel = UUID()
        host.register(panelId: panel, displayTitle: "x", kind: "terminal",
                      tab: Bonsplit.Tab(id: TabID(), title: "x", kind: "terminal"))
        #expect(model.isPanelPinned(panel) == false)
        model.setPanelPinned(panelId: panel, pinned: true)
        #expect(model.isPanelPinned(panel) == true)
        #expect(host.tabs[0].isPinned == true)
        // Repeat pin is a no-op (guarded by wasPinned != pinned).
        host.tabs[0] = Bonsplit.Tab(id: host.tabs[0].id, title: "x", kind: "terminal", isPinned: false)
        model.setPanelPinned(panelId: panel, pinned: true)
        #expect(host.tabs[0].isPinned == false)
    }

    @Test("normalizePinnedTabs reorders pinned tabs to the front, preserving relative order")
    func normalizePinned() {
        let (model, host) = make()
        let a = UUID(), b = UUID(), c = UUID()
        let ta = TabID(), tb = TabID(), tc = TabID()
        host.register(panelId: a, displayTitle: "a", kind: "terminal", tab: Bonsplit.Tab(id: ta, title: "a"))
        host.register(panelId: b, displayTitle: "b", kind: "terminal", tab: Bonsplit.Tab(id: tb, title: "b"))
        host.register(panelId: c, displayTitle: "c", kind: "terminal", tab: Bonsplit.Tab(id: tc, title: "c"))
        model.pinnedPanelIds = [c]
        model.normalizePinnedTabs(in: host.paneId)
        #expect(host.tabs.map(\.id) == [tc, ta, tb])
    }

    @Test("insertionIndexToRight never lands before the pinned prefix")
    func insertionIndex() {
        let (model, host) = make()
        let a = UUID(), b = UUID(), c = UUID()
        let ta = TabID(), tb = TabID(), tc = TabID()
        host.register(panelId: a, displayTitle: "a", kind: "terminal", tab: Bonsplit.Tab(id: ta, title: "a", isPinned: true))
        host.register(panelId: b, displayTitle: "b", kind: "terminal", tab: Bonsplit.Tab(id: tb, title: "b", isPinned: true))
        host.register(panelId: c, displayTitle: "c", kind: "terminal", tab: Bonsplit.Tab(id: tc, title: "c"))
        model.pinnedPanelIds = [a, b]
        // Anchor is the first pinned tab; raw target (1) is clamped up to the pinned count (2).
        #expect(model.insertionIndexToRight(of: ta, inPane: host.paneId) == 2)
        // Anchor missing → tabs.count.
        #expect(model.insertionIndexToRight(of: TabID(), inPane: host.paneId) == 3)
    }

    @Test("syncPinnedStateForTab writes kind+pinned, and skips when already in sync")
    func syncPinnedState() {
        let (model, host) = make()
        let panel = UUID()
        let tabId = TabID()
        host.register(panelId: panel, displayTitle: "x", kind: "terminal",
                      tab: Bonsplit.Tab(id: tabId, title: "x", kind: "terminal", isPinned: false))
        model.pinnedPanelIds = [panel]
        model.syncPinnedStateForTab(tabId, panelId: panel)
        #expect(host.tabs[0].isPinned == true)
        #expect(host.tabs[0].kind == "terminal")
    }

    // MARK: - Close-history eligibility

    @Test("markExplicitClose marks explicit, surface eligibility, and panel eligibility when resolved")
    func markExplicitCloseFull() {
        let model = SurfaceRegistryModel<StubRequest>()
        let surface = TabID()
        let panel = UUID()
        model.markExplicitClose(surfaceId: surface, panelId: panel)
        #expect(model.explicitUserCloseTabIds == [surface])
        #expect(model.closeHistoryEligibleTabIds == [surface])
        #expect(model.closeHistoryEligiblePanelIds == [panel])
    }

    @Test("markExplicitClose with nil panel leaves the panel eligibility set untouched")
    func markExplicitCloseNoPanel() {
        let model = SurfaceRegistryModel<StubRequest>()
        let surface = TabID()
        model.markExplicitClose(surfaceId: surface, panelId: nil)
        #expect(model.explicitUserCloseTabIds == [surface])
        #expect(model.closeHistoryEligibleTabIds == [surface])
        #expect(model.closeHistoryEligiblePanelIds.isEmpty)
    }

    @Test("markCloseHistoryEligible marks panel and resolved surface, but not explicit close")
    func markCloseHistoryEligibleBoth() {
        let model = SurfaceRegistryModel<StubRequest>()
        let surface = TabID()
        let panel = UUID()
        model.markCloseHistoryEligible(panelId: panel, surfaceId: surface)
        #expect(model.closeHistoryEligiblePanelIds == [panel])
        #expect(model.closeHistoryEligibleTabIds == [surface])
        #expect(model.explicitUserCloseTabIds.isEmpty)
    }

    @Test("markTabCloseButtonClose marks explicit-close and button-close, not history eligibility")
    func markTabCloseButton() {
        let model = SurfaceRegistryModel<StubRequest>()
        let surface = TabID()
        model.markTabCloseButtonClose(surfaceId: surface)
        #expect(model.explicitUserCloseTabIds == [surface])
        #expect(model.tabCloseButtonCloseTabIds == [surface])
        #expect(model.closeHistoryEligibleTabIds.isEmpty)
        #expect(model.closeHistoryEligiblePanelIds.isEmpty)
    }

    @Test("consumeCloseHistoryEligibility removes both keys and reports eligibility via OR")
    func consumeEligibility() {
        let model = SurfaceRegistryModel<StubRequest>()
        let surface = TabID()
        let panel = UUID()

        // Eligible by tab only.
        model.closeHistoryEligibleTabIds = [surface]
        #expect(model.consumeCloseHistoryEligibility(tabId: surface, panelId: panel) == true)
        #expect(model.closeHistoryEligibleTabIds.isEmpty)

        // Eligible by panel only.
        model.closeHistoryEligiblePanelIds = [panel]
        #expect(model.consumeCloseHistoryEligibility(tabId: surface, panelId: panel) == true)
        #expect(model.closeHistoryEligiblePanelIds.isEmpty)

        // Neither eligible → false; nil panel does not consume a panel key.
        #expect(model.consumeCloseHistoryEligibility(tabId: surface, panelId: nil) == false)
    }

    @Test("consumeCloseHistoryEligibility always removes the tab key even when consuming a panel-eligible close")
    func consumeRemovesBothKeys() {
        let model = SurfaceRegistryModel<StubRequest>()
        let surface = TabID()
        let panel = UUID()
        model.closeHistoryEligibleTabIds = [surface]
        model.closeHistoryEligiblePanelIds = [panel]
        #expect(model.consumeCloseHistoryEligibility(tabId: surface, panelId: panel) == true)
        #expect(model.closeHistoryEligibleTabIds.isEmpty)
        #expect(model.closeHistoryEligiblePanelIds.isEmpty)
    }

    @Test("clearCloseHistoryEligibility removes both keys without reporting")
    func clearEligibility() {
        let model = SurfaceRegistryModel<StubRequest>()
        let surface = TabID()
        let panel = UUID()
        model.closeHistoryEligibleTabIds = [surface]
        model.closeHistoryEligiblePanelIds = [panel]
        model.clearCloseHistoryEligibility(tabId: surface, panelId: panel)
        #expect(model.closeHistoryEligibleTabIds.isEmpty)
        #expect(model.closeHistoryEligiblePanelIds.isEmpty)
    }

    @Test("consume/remove flag helpers drain the explicit and button-close sets")
    func consumeFlagHelpers() {
        let model = SurfaceRegistryModel<StubRequest>()
        let surface = TabID()
        model.tabCloseButtonCloseTabIds = [surface]
        model.explicitUserCloseTabIds = [surface]

        #expect(model.consumeTabCloseButtonClose(surface) == true)
        #expect(model.tabCloseButtonCloseTabIds.isEmpty)
        #expect(model.consumeTabCloseButtonClose(surface) == false)

        #expect(model.consumeExplicitUserClose(surface) == true)
        #expect(model.explicitUserCloseTabIds.isEmpty)
        #expect(model.consumeExplicitUserClose(surface) == false)

        // removeTabCloseButtonClose is an idempotent no-op when absent.
        model.tabCloseButtonCloseTabIds = [surface]
        model.removeTabCloseButtonClose(surface)
        #expect(model.tabCloseButtonCloseTabIds.isEmpty)
        model.removeTabCloseButtonClose(surface)
        #expect(model.tabCloseButtonCloseTabIds.isEmpty)
    }
}
