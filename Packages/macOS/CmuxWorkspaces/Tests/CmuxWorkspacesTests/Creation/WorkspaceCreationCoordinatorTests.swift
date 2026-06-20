import Foundation
import Testing
import CmuxSettings
@testable import CmuxWorkspaces

@MainActor
private final class CreationStubTab: WorkspaceTabRepresenting {
    let id: UUID
    var groupId: UUID?
    var isPinned: Bool
    var currentDirectory: String
    var title: String
    var focusedPanelId: UUID?
    var panelTitles: [UUID: String] = [:]

    init(id: UUID = UUID(), isPinned: Bool = false) {
        self.id = id
        self.isPinned = isPinned
        self.currentDirectory = "/tmp"
        self.title = ""
    }

    func updatePanelShellActivityState(panelId: UUID, state: PanelShellActivityState) {}
    func setCustomColor(_ hex: String?) {}
    func updatePanelTitle(panelId: UUID, title: String) -> Bool { false }
    func applyProcessTitle(_ title: String) {}
}

@MainActor
@Suite("WorkspaceCreationCoordinator")
struct WorkspaceCreationCoordinatorTests {
    private func makeSettings(placement: WorkspacePlacement, iMessageMode: Bool = false)
        -> (UserDefaultsSettingsClient, SettingCatalog) {
        let defaults = UserDefaults(suiteName: "WorkspaceCreationCoordinatorTests-\(UUID().uuidString)")!
        let catalog = SettingCatalog()
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        settings.set(placement, for: catalog.app.newWorkspacePlacement)
        settings.set(iMessageMode, for: catalog.app.iMessageMode)
        return (settings, catalog)
    }

    private func makeCoordinator(
        tabs: [CreationStubTab],
        selectedId: UUID?,
        placement: WorkspacePlacement,
        iMessageMode: Bool = false
    ) -> (WorkspaceCreationCoordinator<CreationStubTab>, WorkspacesModel<CreationStubTab>) {
        let model = WorkspacesModel<CreationStubTab>()
        model.tabs = tabs
        model.selectedTabId = selectedId
        let (settings, catalog) = makeSettings(placement: placement, iMessageMode: iMessageMode)
        let coordinator = WorkspaceCreationCoordinator(model: model, settings: settings, catalog: catalog)
        return (coordinator, model)
    }

    // MARK: - Snapshot

    @Test func snapshotCapturesIdentityPinAndSelection() {
        let pinned = CreationStubTab(isPinned: true)
        let unpinned = CreationStubTab(isPinned: false)
        let (coordinator, _) = makeCoordinator(
            tabs: [pinned, unpinned],
            selectedId: unpinned.id,
            placement: .end
        )

        let snapshot = coordinator.workspaceCreationSnapshotLite(
            currentTabs: [pinned, unpinned],
            currentSelectedTabId: unpinned.id,
            preferredWorkingDirectory: "/repo",
            inheritedTerminalFontPoints: 13
        )

        #expect(snapshot.tabs.map(\.id) == [pinned.id, unpinned.id])
        #expect(snapshot.tabs.map(\.isPinned) == [true, false])
        #expect(snapshot.selectedTabId == unpinned.id)
        #expect(snapshot.selectedTabWasPinned == false)
        #expect(snapshot.preferredWorkingDirectory == "/repo")
        #expect(snapshot.inheritedTerminalFontPoints == 13)
    }

    @Test func snapshotMarksSelectedPinnedWhenSelectionIsPinned() {
        let pinned = CreationStubTab(isPinned: true)
        let (coordinator, _) = makeCoordinator(tabs: [pinned], selectedId: pinned.id, placement: .end)

        let snapshot = coordinator.workspaceCreationSnapshotLite(
            currentTabs: [pinned],
            currentSelectedTabId: pinned.id,
            preferredWorkingDirectory: nil,
            inheritedTerminalFontPoints: nil
        )

        #expect(snapshot.selectedTabWasPinned == true)
    }

    // MARK: - orderedLiveWorkspaceCreationTabs

    @Test func orderedLiveTabsReturnsSnapshotsInLiveOrder() {
        let a = CreationStubTab()
        let b = CreationStubTab()
        let (coordinator, model) = makeCoordinator(tabs: [a, b], selectedId: a.id, placement: .end)
        let snapshot = coordinator.workspaceCreationSnapshotLite(
            currentTabs: [a, b],
            currentSelectedTabId: a.id,
            preferredWorkingDirectory: nil,
            inheritedTerminalFontPoints: nil
        )

        // Reorder live tabs after capture; the live-order remap follows the model.
        model.tabs = [b, a]
        let ordered = coordinator.orderedLiveWorkspaceCreationTabs(from: snapshot)
        #expect(ordered?.map(\.id) == [b.id, a.id])
    }

    @Test func orderedLiveTabsReturnsNilWhenLiveTabUnknown() {
        let a = CreationStubTab()
        let (coordinator, model) = makeCoordinator(tabs: [a], selectedId: a.id, placement: .end)
        let snapshot = coordinator.workspaceCreationSnapshotLite(
            currentTabs: [a],
            currentSelectedTabId: a.id,
            preferredWorkingDirectory: nil,
            inheritedTerminalFontPoints: nil
        )

        // A new workspace appeared live after capture: the remap bails to nil.
        model.tabs = [a, CreationStubTab()]
        #expect(coordinator.orderedLiveWorkspaceCreationTabs(from: snapshot) == nil)
    }

    // MARK: - newTabInsertIndex placement math

    private func snapshot(
        _ coordinator: WorkspaceCreationCoordinator<CreationStubTab>,
        tabs: [CreationStubTab],
        selectedId: UUID?
    ) -> WorkspaceCreationSnapshot {
        coordinator.workspaceCreationSnapshotLite(
            currentTabs: tabs,
            currentSelectedTabId: selectedId,
            preferredWorkingDirectory: nil,
            inheritedTerminalFontPoints: nil
        )
    }

    @Test func endPlacementInsertsAtEnd() {
        let tabs = [CreationStubTab(), CreationStubTab()]
        let (coordinator, _) = makeCoordinator(tabs: tabs, selectedId: tabs[0].id, placement: .end)
        let snap = snapshot(coordinator, tabs: tabs, selectedId: tabs[0].id)
        #expect(coordinator.newTabInsertIndex(snapshot: snap) == 2)
    }

    @Test func topPlacementInsertsAfterPinned() {
        let pinned = CreationStubTab(isPinned: true)
        let tabs = [pinned, CreationStubTab(), CreationStubTab()]
        let (coordinator, _) = makeCoordinator(tabs: tabs, selectedId: tabs[1].id, placement: .top)
        let snap = snapshot(coordinator, tabs: tabs, selectedId: tabs[1].id)
        #expect(coordinator.newTabInsertIndex(snapshot: snap) == 1)
    }

    @Test func afterCurrentInsertsAfterSelectedUnpinned() {
        let tabs = [CreationStubTab(), CreationStubTab(), CreationStubTab()]
        let (coordinator, _) = makeCoordinator(tabs: tabs, selectedId: tabs[1].id, placement: .afterCurrent)
        let snap = snapshot(coordinator, tabs: tabs, selectedId: tabs[1].id)
        #expect(coordinator.newTabInsertIndex(snapshot: snap) == 2)
    }

    @Test func afterCurrentWithPinnedSelectionInsertsAfterPinnedRun() {
        let pinnedA = CreationStubTab(isPinned: true)
        let pinnedB = CreationStubTab(isPinned: true)
        let tabs = [pinnedA, pinnedB, CreationStubTab()]
        let (coordinator, _) = makeCoordinator(tabs: tabs, selectedId: pinnedA.id, placement: .afterCurrent)
        let snap = snapshot(coordinator, tabs: tabs, selectedId: pinnedA.id)
        #expect(coordinator.newTabInsertIndex(snapshot: snap) == 2)
    }

    @Test func placementOverrideWinsOverStoredSetting() {
        let tabs = [CreationStubTab(), CreationStubTab()]
        let (coordinator, _) = makeCoordinator(tabs: tabs, selectedId: tabs[1].id, placement: .end)
        let snap = snapshot(coordinator, tabs: tabs, selectedId: tabs[1].id)
        #expect(coordinator.newTabInsertIndex(snapshot: snap, placementOverride: .top) == 0)
    }

    @Test func iMessageModePinsTopPlacement() {
        let pinned = CreationStubTab(isPinned: true)
        let tabs = [pinned, CreationStubTab()]
        let (coordinator, _) = makeCoordinator(
            tabs: tabs,
            selectedId: tabs[1].id,
            placement: .end,
            iMessageMode: true
        )
        let snap = snapshot(coordinator, tabs: tabs, selectedId: tabs[1].id)
        // iMessage mode forces .top → insert after the single pinned row.
        #expect(coordinator.newTabInsertIndex(snapshot: snap) == 1)
    }
}
