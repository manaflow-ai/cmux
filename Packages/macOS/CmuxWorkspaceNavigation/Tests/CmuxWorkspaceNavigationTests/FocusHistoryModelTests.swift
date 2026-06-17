import Foundation
import Testing
@testable import CmuxWorkspaceNavigation

/// In-memory window host: a dictionary of workspaces/panels plus counters
/// for the mutations a navigation performs.
@MainActor
private final class FakeFocusHistoryHost: FocusHistoryHosting {
    struct WorkspaceState {
        var title: String
        var panels: [UUID: String]
        var rememberedFocusedPanelId: UUID?
        var focusedPanelId: UUID?
    }

    var workspaces: [UUID: WorkspaceState] = [:]
    var selectedWorkspaceId: UUID?
    var revisionBumps = 0
    var focusedPanels: [(workspaceId: UUID, panelId: UUID)] = []
    var flashedPanels: [(workspaceId: UUID, panelId: UUID)] = []
    var focusSelectedWorkspacePanelCalls = 0

    func workspaceExists(_ workspaceId: UUID) -> Bool {
        workspaces[workspaceId] != nil
    }

    func panelExists(workspaceId: UUID, panelId: UUID) -> Bool {
        workspaces[workspaceId]?.panels[panelId] != nil
    }

    func workspaceTitle(_ workspaceId: UUID) -> String? {
        workspaces[workspaceId]?.title
    }

    func panelTitle(workspaceId: UUID, panelId: UUID) -> String? {
        workspaces[workspaceId]?.panels[panelId]
    }

    func rememberedFocusedPanelId(_ workspaceId: UUID) -> UUID? {
        workspaces[workspaceId]?.rememberedFocusedPanelId
    }

    func workspaceFocusedPanelId(_ workspaceId: UUID) -> UUID? {
        workspaces[workspaceId]?.focusedPanelId
    }

    func firstPanelIdSortedByUUIDString(_ workspaceId: UUID) -> UUID? {
        workspaces[workspaceId]?.panels.keys.sorted { $0.uuidString < $1.uuidString }.first
    }

    func selectWorkspace(_ workspaceId: UUID) {
        if selectedWorkspaceId != workspaceId {
            selectedWorkspaceId = workspaceId
        }
    }

    func rememberFocusedSurface(workspaceId: UUID, surfaceId: UUID) {
        workspaces[workspaceId]?.rememberedFocusedPanelId = surfaceId
    }

    func focusPanel(workspaceId: UUID, panelId: UUID) {
        focusedPanels.append((workspaceId, panelId))
    }

    func triggerFocusFlash(workspaceId: UUID, panelId: UUID) {
        flashedPanels.append((workspaceId, panelId))
    }

    func focusSelectedWorkspacePanel() {
        focusSelectedWorkspacePanelCalls += 1
    }

    func focusHistoryRevisionDidChange() {
        revisionBumps += 1
    }

    @discardableResult
    func addWorkspace(title: String = "ws", panels: [UUID: String] = [:]) -> UUID {
        let id = UUID()
        workspaces[id] = WorkspaceState(title: title, panels: panels)
        return id
    }
}

@MainActor
@Suite("FocusHistoryModel")
struct FocusHistoryModelTests {
    private func makeModel(maxHistorySize: Int = 50) -> (FocusHistoryModel, FakeFocusHistoryHost) {
        let host = FakeFocusHistoryHost()
        let model = FocusHistoryModel(maxHistorySize: maxHistorySize)
        model.attach(host: host)
        return (model, host)
    }

    @Test func recordAndNavigateBackForwardAcrossWorkspaces() {
        let (model, host) = makeModel()
        let panelA = UUID()
        let panelB = UUID()
        let wsA = host.addWorkspace(title: "A", panels: [panelA: "pa"])
        let wsB = host.addWorkspace(title: "B", panels: [panelB: "pb"])

        host.selectedWorkspaceId = wsA
        host.workspaces[wsA]?.rememberedFocusedPanelId = panelA
        model.recordFocusInHistory(workspaceId: wsA, panelId: panelA, preservingForwardBranch: false)

        host.selectedWorkspaceId = wsB
        host.workspaces[wsB]?.rememberedFocusedPanelId = panelB
        model.recordFocusInHistory(workspaceId: wsB, panelId: panelB, preservingForwardBranch: false)

        #expect(model.canNavigateBack)
        #expect(!model.canNavigateForward)

        #expect(model.navigateBack())
        #expect(host.selectedWorkspaceId == wsA)
        #expect(model.canNavigateForward)

        #expect(model.navigateForward())
        #expect(host.selectedWorkspaceId == wsB)
    }

    @Test func recordingDropsOldestEntriesBeyondCap() {
        let (model, host) = makeModel(maxHistorySize: 3)
        var workspaceIds: [UUID] = []
        for index in 0..<5 {
            let panel = UUID()
            let ws = host.addWorkspace(title: "ws\(index)", panels: [panel: "p"])
            workspaceIds.append(ws)
            host.selectedWorkspaceId = ws
            host.workspaces[ws]?.rememberedFocusedPanelId = panel
            model.recordFocusInHistory(workspaceId: ws, panelId: panel, preservingForwardBranch: false)
        }

        // Cap 3: only ws2 and ws3 remain behind the current ws4 position.
        #expect(model.navigateBack())
        #expect(host.selectedWorkspaceId == workspaceIds[3])
        #expect(model.navigateBack())
        #expect(host.selectedWorkspaceId == workspaceIds[2])
        #expect(!model.navigateBack())
    }

    @Test func duplicateRecordAtCurrentPositionIsNoOp() {
        let (model, host) = makeModel()
        let panel = UUID()
        let ws = host.addWorkspace(panels: [panel: "p"])
        host.selectedWorkspaceId = ws

        model.recordFocusInHistory(workspaceId: ws, panelId: panel, preservingForwardBranch: false)
        let bumps = host.revisionBumps
        model.recordFocusInHistory(workspaceId: ws, panelId: panel, preservingForwardBranch: false)
        #expect(host.revisionBumps == bumps)
    }

    @Test func recordingIgnoresUnknownWorkspacesAndPanels() {
        let (model, host) = makeModel()
        let ws = host.addWorkspace(panels: [:])

        model.recordFocusInHistory(workspaceId: UUID(), panelId: nil, preservingForwardBranch: false)
        model.recordFocusInHistory(workspaceId: ws, panelId: UUID(), preservingForwardBranch: false)
        #expect(host.revisionBumps == 0)
        #expect(!model.canNavigateBack)
    }

    @Test func preservingForwardBranchInsertsAfterCurrentWithoutDroppingForwardStack() {
        let (model, host) = makeModel()
        var panels: [UUID] = []
        var workspaceIds: [UUID] = []
        for index in 0..<3 {
            let panel = UUID()
            panels.append(panel)
            let ws = host.addWorkspace(title: "ws\(index)", panels: [panel: "p"])
            workspaceIds.append(ws)
            host.selectedWorkspaceId = ws
            host.workspaces[ws]?.rememberedFocusedPanelId = panel
            model.recordFocusInHistory(workspaceId: ws, panelId: panel, preservingForwardBranch: false)
        }

        // Step back to ws1 so ws2 sits on the forward stack.
        #expect(model.navigateBack())
        #expect(model.canNavigateForward)

        // A restore-style record keeps the forward stack.
        let restoredPanel = UUID()
        let restoredWs = host.addWorkspace(title: "restored", panels: [restoredPanel: "p"])
        host.workspaces[restoredWs]?.rememberedFocusedPanelId = restoredPanel
        host.selectedWorkspaceId = restoredWs
        model.recordFocusInHistory(workspaceId: restoredWs, panelId: restoredPanel, preservingForwardBranch: true)

        #expect(model.canNavigateForward)
    }

    @Test func implicitFocusCoalescesWithCurrentMidStackEntryForSameWorkspace() {
        let (model, host) = makeModel()
        let panelA = UUID()
        let panelB = UUID()
        let otherPanel = UUID()
        let ws = host.addWorkspace(panels: [panelA: "a", panelB: "b"])
        let other = host.addWorkspace(panels: [otherPanel: "p"])

        host.selectedWorkspaceId = ws
        model.recordFocusInHistory(workspaceId: ws, panelId: panelA, preservingForwardBranch: false)
        host.selectedWorkspaceId = other
        host.workspaces[other]?.rememberedFocusedPanelId = otherPanel
        model.recordFocusInHistory(workspaceId: other, panelId: otherPanel, preservingForwardBranch: false)

        // Back to the mid-stack ws entry, then an implicit focus on another
        // panel of the same workspace rewrites the entry in place.
        host.workspaces[ws]?.rememberedFocusedPanelId = panelA
        #expect(model.navigateBack())
        let bumps = host.revisionBumps
        model.recordImplicitFocusInHistory(workspaceId: ws, panelId: panelB)
        #expect(host.revisionBumps == bumps + 1)
        // Forward stack intact: implicit focus never truncates it.
        #expect(model.canNavigateForward)
    }

    @Test func invalidateWorkspaceRemovesItsEntriesAndClampsIndex() {
        let (model, host) = makeModel()
        let panelA = UUID()
        let panelB = UUID()
        let wsA = host.addWorkspace(panels: [panelA: "a"])
        let wsB = host.addWorkspace(panels: [panelB: "b"])

        host.selectedWorkspaceId = wsA
        host.workspaces[wsA]?.rememberedFocusedPanelId = panelA
        model.recordFocusInHistory(workspaceId: wsA, panelId: panelA, preservingForwardBranch: false)
        host.selectedWorkspaceId = wsB
        host.workspaces[wsB]?.rememberedFocusedPanelId = panelB
        model.recordFocusInHistory(workspaceId: wsB, panelId: panelB, preservingForwardBranch: false)

        host.workspaces.removeValue(forKey: wsA)
        model.invalidateFocusHistoryTarget(workspaceId: wsA, panelId: nil)

        #expect(!model.canNavigateBack)
        #expect(!model.navigateBack())
    }

    @Test func invalidatePanelOnlyBumpsRevisionWhenPanelIsInHistory() {
        let (model, host) = makeModel()
        let panel = UUID()
        let ws = host.addWorkspace(panels: [panel: "p"])
        host.selectedWorkspaceId = ws
        model.recordFocusInHistory(workspaceId: ws, panelId: panel, preservingForwardBranch: false)

        let bumps = host.revisionBumps
        model.invalidateFocusHistoryTarget(workspaceId: ws, panelId: UUID())
        #expect(host.revisionBumps == bumps)
        model.invalidateFocusHistoryTarget(workspaceId: ws, panelId: panel)
        #expect(host.revisionBumps == bumps + 1)
    }

    @Test func menuSnapshotListsBackEntriesMostRecentFirstAndTruncates() {
        let (model, host) = makeModel()
        var workspaceIds: [UUID] = []
        for index in 0..<4 {
            let panel = UUID()
            let ws = host.addWorkspace(title: "ws\(index)", panels: [panel: "panel\(index)"])
            workspaceIds.append(ws)
            host.selectedWorkspaceId = ws
            host.workspaces[ws]?.rememberedFocusedPanelId = panel
            model.recordFocusInHistory(workspaceId: ws, panelId: panel, preservingForwardBranch: false)
        }

        let snapshot = model.focusHistoryMenuSnapshot(direction: .back, maxItemCount: nil)
        #expect(snapshot.items.map(\.workspaceTitle) == ["ws2", "ws1", "ws0"])
        #expect(snapshot.totalItemCount == 3)
        #expect(!snapshot.isLimited)

        let limited = model.focusHistoryMenuSnapshot(direction: .back, maxItemCount: 2)
        #expect(limited.items.count == 2)
        #expect(limited.totalItemCount == 3)
        #expect(limited.isLimited)
        #expect(limited.items.allSatisfy { $0.position == .older })
    }

    @Test func menuSnapshotResolvesClosedPanelToWorkspaceLevelEntry() {
        let (model, host) = makeModel()
        let panelA = UUID()
        let panelB = UUID()
        let otherPanel = UUID()
        let ws = host.addWorkspace(title: "A", panels: [panelA: "pa", panelB: "pb"])
        let other = host.addWorkspace(title: "B", panels: [otherPanel: "p"])

        host.selectedWorkspaceId = ws
        model.recordFocusInHistory(workspaceId: ws, panelId: panelA, preservingForwardBranch: false)
        host.selectedWorkspaceId = other
        host.workspaces[other]?.rememberedFocusedPanelId = otherPanel
        model.recordFocusInHistory(workspaceId: other, panelId: otherPanel, preservingForwardBranch: false)

        // Close panel A; the entry resolves through the remembered panel.
        host.workspaces[ws]?.panels.removeValue(forKey: panelA)
        host.workspaces[ws]?.rememberedFocusedPanelId = panelB

        let snapshot = model.focusHistoryMenuSnapshot(direction: .back, maxItemCount: nil)
        #expect(snapshot.items.count == 1)
        #expect(snapshot.items.first?.panelTitle == "pb")
    }

    @Test func navigateToMenuItemFallsBackToLastMatchingEntryWhenIndexMoved() throws {
        let (model, host) = makeModel()
        let panelA = UUID()
        let panelB = UUID()
        let wsA = host.addWorkspace(title: "A", panels: [panelA: "pa"])
        let wsB = host.addWorkspace(title: "B", panels: [panelB: "pb"])

        host.selectedWorkspaceId = wsA
        host.workspaces[wsA]?.rememberedFocusedPanelId = panelA
        model.recordFocusInHistory(workspaceId: wsA, panelId: panelA, preservingForwardBranch: false)
        host.selectedWorkspaceId = wsB
        host.workspaces[wsB]?.rememberedFocusedPanelId = panelB
        model.recordFocusInHistory(workspaceId: wsB, panelId: panelB, preservingForwardBranch: false)

        let snapshot = model.focusHistoryMenuSnapshot(direction: .back, maxItemCount: nil)
        let item = try #require(snapshot.items.first)
        let shiftedItem = FocusHistoryMenuItem(
            historyIndex: item.historyIndex + 7,
            entry: item.entry,
            workspaceTitle: item.workspaceTitle,
            panelTitle: item.panelTitle,
            position: item.position,
            focusedAt: item.focusedAt,
            isNavigable: item.isNavigable
        )
        #expect(model.navigateToFocusHistoryMenuItem(shiftedItem))
        #expect(host.selectedWorkspaceId == wsA)
    }

    @Test func recentlyFocusedMergesBackAndForwardByRecency() {
        let older = FocusHistoryMenuItem(
            historyIndex: 0,
            entry: FocusHistoryEntry(workspaceId: UUID(), panelId: nil),
            workspaceTitle: "older",
            panelTitle: nil,
            position: .older,
            focusedAt: Date(timeIntervalSince1970: 100),
            isNavigable: true
        )
        let newer = FocusHistoryMenuItem(
            historyIndex: 2,
            entry: FocusHistoryEntry(workspaceId: UUID(), panelId: nil),
            workspaceTitle: "newer",
            panelTitle: nil,
            position: .newer,
            focusedAt: Date(timeIntervalSince1970: 200),
            isNavigable: true
        )
        let merged = FocusHistoryMenuSnapshot.recentlyFocused(
            back: FocusHistoryMenuSnapshot(items: [older], totalItemCount: 1, isLimited: false),
            forward: FocusHistoryMenuSnapshot(items: [newer], totalItemCount: 1, isLimited: false),
            maxItemCount: nil
        )
        #expect(merged.items.map(\.workspaceTitle) == ["newer", "older"])

        let limited = FocusHistoryMenuSnapshot.recentlyFocused(
            back: FocusHistoryMenuSnapshot(items: [older], totalItemCount: 1, isLimited: false),
            forward: FocusHistoryMenuSnapshot(items: [newer], totalItemCount: 1, isLimited: false),
            maxItemCount: 1
        )
        #expect(limited.items.map(\.workspaceTitle) == ["newer"])
        #expect(limited.isLimited)
        #expect(limited.totalItemCount == 2)
    }

    @Test func suppressionBlocksRecordingAndGenerationsAreConsumedOnce() {
        let (model, host) = makeModel()
        let panel = UUID()
        let ws = host.addWorkspace(panels: [panel: "p"])
        host.selectedWorkspaceId = ws

        model.withFocusHistoryRecordingSuppressed {
            #expect(!model.shouldRecordFocusHistory)
            model.recordFocusInHistory(workspaceId: ws, panelId: panel, preservingForwardBranch: false)
        }
        #expect(model.shouldRecordFocusHistory)
        #expect(host.revisionBumps == 0)

        model.markSuppressedSelectionSideEffectGeneration(7)
        #expect(model.consumeSuppressedSelectionSideEffectGeneration(7))
        #expect(!model.consumeSuppressedSelectionSideEffectGeneration(7))
    }

    @Test func navigateBackPrunesEntriesWhoseWorkspaceIsGone() {
        let (model, host) = makeModel()
        let panelA = UUID()
        let panelB = UUID()
        let panelC = UUID()
        let wsA = host.addWorkspace(title: "A", panels: [panelA: "pa"])
        let wsB = host.addWorkspace(title: "B", panels: [panelB: "pb"])
        let wsC = host.addWorkspace(title: "C", panels: [panelC: "pc"])

        for (ws, panel) in [(wsA, panelA), (wsB, panelB), (wsC, panelC)] {
            host.selectedWorkspaceId = ws
            host.workspaces[ws]?.rememberedFocusedPanelId = panel
            model.recordFocusInHistory(workspaceId: ws, panelId: panel, preservingForwardBranch: false)
        }

        // Drop wsB without invalidating: navigateBack prunes it inline and
        // lands on wsA.
        host.workspaces.removeValue(forKey: wsB)
        #expect(model.navigateBack())
        #expect(host.selectedWorkspaceId == wsA)
    }

    @Test func resetClearsAllState() {
        let (model, host) = makeModel()
        let panelA = UUID()
        let panelB = UUID()
        let wsA = host.addWorkspace(panels: [panelA: "a"])
        let wsB = host.addWorkspace(panels: [panelB: "b"])
        host.selectedWorkspaceId = wsA
        host.workspaces[wsA]?.rememberedFocusedPanelId = panelA
        model.recordFocusInHistory(workspaceId: wsA, panelId: panelA, preservingForwardBranch: false)
        host.selectedWorkspaceId = wsB
        host.workspaces[wsB]?.rememberedFocusedPanelId = panelB
        model.recordFocusInHistory(workspaceId: wsB, panelId: panelB, preservingForwardBranch: false)
        model.markSuppressedSelectionSideEffectGeneration(1)

        let bumps = host.revisionBumps
        model.reset()
        // reset() itself never bumps; the window-reset path owns that bump.
        #expect(host.revisionBumps == bumps)
        #expect(!model.canNavigateBack)
        #expect(!model.canNavigateForward)
        #expect(!model.consumeSuppressedSelectionSideEffectGeneration(1))
        #expect(model.currentFocusHistoryEntry?.workspaceId == wsB)
    }
}
