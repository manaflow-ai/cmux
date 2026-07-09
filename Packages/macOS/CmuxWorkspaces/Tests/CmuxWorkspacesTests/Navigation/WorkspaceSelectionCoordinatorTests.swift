import Foundation
import Testing
@testable import CmuxWorkspaces

@MainActor
private final class SelectionStubTab: WorkspaceTabRepresenting {
    let id: UUID
    var groupId: UUID?
    var isPinned: Bool
    var currentDirectory: String
    var title: String

    init(id: UUID = UUID()) {
        self.id = id
        self.groupId = nil
        self.isPinned = false
        self.currentDirectory = "/tmp"
        self.title = ""
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

/// Drives the model's selection didSet so the navigation flow can flip
/// `selectedTabId` exactly like production. The fake stands in for the legacy
/// `selectWorkspaceId` mutation: `selectWorkspaceFromNavigation(id:)` writes the
/// model's `selectedTabId` (the observable effect the navigation gestures
/// produce) and records the call so the order math can be asserted.
@MainActor
private final class RecordingSelectionHost: WorkspaceSelectionHosting {
    let model: WorkspacesModel<SelectionStubTab>
    private(set) var selectedIds: [UUID] = []
    private(set) var collapsedExcept: [UUID] = []

    init(model: WorkspacesModel<SelectionStubTab>) {
        self.model = model
    }

    func selectWorkspaceFromNavigation(id: UUID) {
        selectedIds.append(id)
        model.selectedTabId = id
    }

    func collapseSidebarMultiSelection(except workspaceId: UUID) {
        collapsedExcept.append(workspaceId)
    }

    func debugPrimeWorkspaceSwitch(trigger: String, to target: UUID?) {}
    func debugPrepareWorkspaceSwitch(trigger: String, from: UUID?, to: UUID?) {}
    func debugLogWorkspaceCycleHotOn(generation: UInt64) {}
    func debugLogWorkspaceCycleHotCancelPrevious(generation: UInt64) {}
    func debugLogWorkspaceCycleHotCooldownCanceled(generation: UInt64) {}
    func debugLogWorkspaceCycleHotOff(generation: UInt64) {}
}

@MainActor
private func makeFixture(
    count: Int
) -> (
    coordinator: WorkspaceSelectionCoordinator<SelectionStubTab>,
    model: WorkspacesModel<SelectionStubTab>,
    backgroundLoad: BackgroundWorkspaceLoadModel,
    host: RecordingSelectionHost,
    tabs: [SelectionStubTab]
) {
    let model = WorkspacesModel<SelectionStubTab>()
    let backgroundLoad = BackgroundWorkspaceLoadModel()
    let coordinator = WorkspaceSelectionCoordinator(model: model, backgroundLoad: backgroundLoad)
    let host = RecordingSelectionHost(model: model)
    coordinator.attach(host: host)
    let tabs = (0..<count).map { _ in SelectionStubTab() }
    model.tabs = tabs
    return (coordinator, model, backgroundLoad, host, tabs)
}

@MainActor
@Suite struct WorkspaceSelectionCoordinatorTests {
    @Test func selectNextTabAdvancesAndWraps() {
        let f = makeFixture(count: 3)
        f.model.selectedTabId = f.tabs[2].id

        f.coordinator.selectNextTab()
        #expect(f.host.selectedIds == [f.tabs[0].id])  // wraps 2 -> 0
        #expect(f.model.selectedTabId == f.tabs[0].id)
        #expect(f.host.collapsedExcept == [f.tabs[0].id])

        f.coordinator.selectNextTab()
        #expect(f.host.selectedIds == [f.tabs[0].id, f.tabs[1].id])
    }

    @Test func selectPreviousTabRetreatsAndWraps() {
        let f = makeFixture(count: 3)
        f.model.selectedTabId = f.tabs[0].id

        f.coordinator.selectPreviousTab()
        #expect(f.host.selectedIds == [f.tabs[2].id])  // wraps 0 -> 2
        #expect(f.host.collapsedExcept == [f.tabs[2].id])
    }

    @Test func selectNextTabNoopsWithoutSelection() {
        let f = makeFixture(count: 3)
        f.model.selectedTabId = nil
        f.coordinator.selectNextTab()
        #expect(f.host.selectedIds.isEmpty)
        #expect(f.host.collapsedExcept.isEmpty)
    }

    @Test func selectNextTabNoopsWhenSelectionNotInTabs() {
        let f = makeFixture(count: 2)
        f.model.selectedTabId = UUID()  // not present in tabs
        f.coordinator.selectNextTab()
        #expect(f.host.selectedIds.isEmpty)
    }

    @Test func selectTabAtIndexSelectsInRange() {
        let f = makeFixture(count: 3)
        f.coordinator.selectTab(at: 1)
        #expect(f.host.selectedIds == [f.tabs[1].id])
    }

    @Test func selectTabAtIndexIgnoresOutOfRange() {
        let f = makeFixture(count: 3)
        f.coordinator.selectTab(at: -1)
        f.coordinator.selectTab(at: 3)
        #expect(f.host.selectedIds.isEmpty)
    }

    @Test func selectLastTabSelectsFinalTab() {
        let f = makeFixture(count: 3)
        f.coordinator.selectLastTab()
        #expect(f.host.selectedIds == [f.tabs[2].id])
    }

    @Test func selectLastTabNoopsWhenEmpty() {
        let f = makeFixture(count: 0)
        f.coordinator.selectLastTab()
        #expect(f.host.selectedIds.isEmpty)
    }

    @Test func cycleNavigationActivatesHotWindow() {
        let f = makeFixture(count: 2)
        f.model.selectedTabId = f.tabs[0].id
        #expect(f.backgroundLoad.isWorkspaceCycleHot == false)
        f.coordinator.selectNextTab()
        #expect(f.backgroundLoad.isWorkspaceCycleHot == true)
    }

    @Test func directSelectionDoesNotActivateHotWindow() {
        let f = makeFixture(count: 3)
        f.coordinator.selectTab(at: 1)
        #expect(f.backgroundLoad.isWorkspaceCycleHot == false)
        f.coordinator.selectLastTab()
        #expect(f.backgroundLoad.isWorkspaceCycleHot == false)
    }

    @Test func resetClearsHotWindow() {
        let f = makeFixture(count: 2)
        f.coordinator.activateWorkspaceCycleHotWindow()
        #expect(f.backgroundLoad.isWorkspaceCycleHot == true)
        f.coordinator.resetWorkspaceCycleHotWindow()
        #expect(f.backgroundLoad.isWorkspaceCycleHot == false)
    }

    @Test func cooldownFlipsHotWindowOff() async throws {
        let f = makeFixture(count: 2)
        f.coordinator.activateWorkspaceCycleHotWindow()
        #expect(f.backgroundLoad.isWorkspaceCycleHot == true)
        // The cooldown sleeps ~220ms before clearing; wait past it.
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(f.backgroundLoad.isWorkspaceCycleHot == false)
    }
}
