import Foundation
import Testing
@testable import CmuxWorkspaces

@MainActor
private final class MetadataStubTab: WorkspaceTabRepresenting {
    let id: UUID
    var groupId: UUID?
    var isPinned: Bool
    var currentDirectory: String
    var title: String
    var focusedPanelId: UUID?
    var panelTitles: [UUID: String] = [:]
    private(set) var shellActivityUpdates: [(panelId: UUID, state: PanelShellActivityState)] = []
    private(set) var panelTitleUpdates: [(panelId: UUID, title: String)] = []
    private(set) var appliedProcessTitles: [String] = []

    init(id: UUID = UUID(), title: String = "", focusedPanelId: UUID? = nil) {
        self.id = id
        self.groupId = nil
        self.isPinned = false
        self.currentDirectory = "/tmp"
        self.title = title
        self.focusedPanelId = focusedPanelId
    }

    func updatePanelShellActivityState(panelId: UUID, state: PanelShellActivityState) {
        shellActivityUpdates.append((panelId, state))
    }
    func setCustomColor(_ hex: String?) {}
    // This fake never participates in panel-id resolution.
    func panelExists(_ panelId: UUID) -> Bool { false }
    func panelId(forSurfaceId surfaceId: UUID) -> UUID? { nil }

    @discardableResult
    func updatePanelTitle(panelId: UUID, title: String) -> Bool {
        panelTitleUpdates.append((panelId, title))
        let changed = panelTitles[panelId] != title
        panelTitles[panelId] = title
        return changed
    }

    func applyProcessTitle(_ title: String) {
        appliedProcessTitles.append(title)
    }
}

/// Records the app-coupled title effects the coordinator forwards through
/// ``SurfaceMetadataTitleHosting``.
@MainActor
private final class TitleHostSpy: SurfaceMetadataTitleHosting {
    private(set) var windowTitleRefreshWorkspaceIds: [UUID] = []
    private(set) var enqueueLogs: [(workspaceId: UUID, panelId: UUID, title: String)] = []

    func surfaceMetadataUpdateWindowTitleIfSelected(workspaceId: UUID) {
        windowTitleRefreshWorkspaceIds.append(workspaceId)
    }
    func surfaceMetadataLogPanelTitleEnqueue(workspaceId: UUID, panelId: UUID, title: String) {
        enqueueLogs.append((workspaceId, panelId, title))
    }
}

/// Captures the flush actions the coordinator schedules through its
/// ``TitleFlushScheduling`` seam so a test can drive the coalescer tick
/// synchronously instead of waiting on the real `1.0 / 30.0` delay.
@MainActor
private final class FlushSchedulerSpy: TitleFlushScheduling {
    private(set) var scheduledFlushes: [() -> Void] = []

    func signal(_ action: @escaping () -> Void) {
        scheduledFlushes.append(action)
    }

    /// Runs the most recently scheduled flush, mirroring one coalescer tick.
    func runLatestFlush() {
        scheduledFlushes.last?()
    }
}

@MainActor
struct SurfaceMetadataCoordinatorTests {
    private func makeCoordinator(
        _ tabs: [MetadataStubTab]
    ) -> (
        SurfaceMetadataCoordinator<MetadataStubTab>,
        WorkspacesModel<MetadataStubTab>,
        FlushSchedulerSpy
    ) {
        let model = WorkspacesModel<MetadataStubTab>()
        model.tabs = tabs
        let scheduler = FlushSchedulerSpy()
        let coordinator = SurfaceMetadataCoordinator(model: model, titleFlushScheduler: scheduler)
        return (coordinator, model, scheduler)
    }

    @Test
    func titleForTabReturnsTheMatchingWorkspaceTitle() {
        let tab = MetadataStubTab(title: "feat-x")
        let (coordinator, _, _) = makeCoordinator([MetadataStubTab(title: "other"), tab])

        #expect(coordinator.titleForTab(tab.id) == "feat-x")
    }

    @Test
    func titleForTabReturnsNilForUnknownWorkspace() {
        let (coordinator, _, _) = makeCoordinator([MetadataStubTab(title: "a")])

        #expect(coordinator.titleForTab(UUID()) == nil)
    }

    @Test
    func applyShellActivityMutatesOwningWorkspaceAndReportsRefreshOnPromptIdle() {
        let tab = MetadataStubTab()
        let (coordinator, _, _) = makeCoordinator([tab])
        let surfaceId = UUID()

        let shouldRefresh = coordinator.applySurfaceShellActivity(
            tabId: tab.id,
            surfaceId: surfaceId,
            state: .promptIdle
        )

        #expect(shouldRefresh)
        #expect(tab.shellActivityUpdates.count == 1)
        #expect(tab.shellActivityUpdates.first?.panelId == surfaceId)
        #expect(tab.shellActivityUpdates.first?.state == .promptIdle)
    }

    @Test
    func applyShellActivityMutatesButDoesNotRefreshForNonPromptIdle() {
        let tab = MetadataStubTab()
        let (coordinator, _, _) = makeCoordinator([tab])
        let surfaceId = UUID()

        let shouldRefresh = coordinator.applySurfaceShellActivity(
            tabId: tab.id,
            surfaceId: surfaceId,
            state: .commandRunning
        )

        #expect(!shouldRefresh)
        #expect(tab.shellActivityUpdates.map(\.state) == [.commandRunning])
    }

    @Test
    func applyShellActivityNoOpsAndDoesNotRefreshWhenWorkspaceIsMissing() {
        let present = MetadataStubTab()
        let (coordinator, _, _) = makeCoordinator([present])

        let shouldRefresh = coordinator.applySurfaceShellActivity(
            tabId: UUID(),
            surfaceId: UUID(),
            state: .promptIdle
        )

        #expect(!shouldRefresh)
        #expect(present.shellActivityUpdates.isEmpty)
    }

    @Test
    func enqueueDropsEmptyTitleWithoutSchedulingOrLogging() {
        let tab = MetadataStubTab()
        let (coordinator, _, scheduler) = makeCoordinator([tab])
        let host = TitleHostSpy()
        coordinator.attach(titleHost: host)

        coordinator.enqueuePanelTitleUpdate(tabId: tab.id, panelId: UUID(), title: "   \n ")

        #expect(scheduler.scheduledFlushes.isEmpty)
        #expect(host.enqueueLogs.isEmpty)
    }

    @Test
    func enqueueTrimsTitleSchedulesFlushAndLogsTrimmedValue() {
        let tab = MetadataStubTab()
        let (coordinator, _, scheduler) = makeCoordinator([tab])
        let host = TitleHostSpy()
        coordinator.attach(titleHost: host)
        let panelId = UUID()

        coordinator.enqueuePanelTitleUpdate(tabId: tab.id, panelId: panelId, title: "  zsh  ")

        #expect(scheduler.scheduledFlushes.count == 1)
        #expect(host.enqueueLogs.count == 1)
        #expect(host.enqueueLogs.first?.title == "zsh")
        #expect(host.enqueueLogs.first?.panelId == panelId)
    }

    @Test
    func flushAppliesLatestCoalescedTitlePerPanelAndRefreshesFocusedSelectedTitle() {
        let panelId = UUID()
        let tab = MetadataStubTab(focusedPanelId: panelId)
        let (coordinator, _, scheduler) = makeCoordinator([tab])
        let host = TitleHostSpy()
        coordinator.attach(titleHost: host)

        coordinator.enqueuePanelTitleUpdate(tabId: tab.id, panelId: panelId, title: "first")
        coordinator.enqueuePanelTitleUpdate(tabId: tab.id, panelId: panelId, title: "second")
        scheduler.runLatestFlush()

        // Only the latest title for the panel is applied (coalesced).
        #expect(tab.panelTitleUpdates.map(\.title) == ["second"])
        // Focused panel -> process title applied and window-title refresh requested.
        #expect(tab.appliedProcessTitles == ["second"])
        #expect(host.windowTitleRefreshWorkspaceIds == [tab.id])
    }

    @Test
    func flushDoesNotApplyProcessTitleForUnfocusedPanel() {
        let focused = UUID()
        let other = UUID()
        let tab = MetadataStubTab(focusedPanelId: focused)
        let (coordinator, _, scheduler) = makeCoordinator([tab])
        let host = TitleHostSpy()
        coordinator.attach(titleHost: host)

        coordinator.enqueuePanelTitleUpdate(tabId: tab.id, panelId: other, title: "bg")
        scheduler.runLatestFlush()

        #expect(tab.panelTitleUpdates.map(\.title) == ["bg"])
        #expect(tab.appliedProcessTitles.isEmpty)
        #expect(host.windowTitleRefreshWorkspaceIds.isEmpty)
    }

    @Test
    func resetPendingDropsQueuedUpdatesSoFlushIsANoOp() {
        let panelId = UUID()
        let tab = MetadataStubTab(focusedPanelId: panelId)
        let (coordinator, _, scheduler) = makeCoordinator([tab])
        let host = TitleHostSpy()
        coordinator.attach(titleHost: host)

        coordinator.enqueuePanelTitleUpdate(tabId: tab.id, panelId: panelId, title: "pending")
        coordinator.resetPendingPanelTitleUpdates()
        scheduler.runLatestFlush()

        #expect(tab.panelTitleUpdates.isEmpty)
        #expect(tab.appliedProcessTitles.isEmpty)
    }

    @Test
    func focusedSurfaceTitleDidChangeReappliesFocusedPanelTitle() {
        let panelId = UUID()
        let tab = MetadataStubTab(focusedPanelId: panelId)
        tab.panelTitles[panelId] = "vim"
        let (coordinator, _, _) = makeCoordinator([tab])
        let host = TitleHostSpy()
        coordinator.attach(titleHost: host)

        coordinator.focusedSurfaceTitleDidChange(tabId: tab.id)

        #expect(tab.appliedProcessTitles == ["vim"])
        #expect(host.windowTitleRefreshWorkspaceIds == [tab.id])
    }

    @Test
    func focusedSurfaceTitleDidChangeNoOpsWithoutFocusOrTitle() {
        let tab = MetadataStubTab(focusedPanelId: nil)
        let (coordinator, _, _) = makeCoordinator([tab])
        let host = TitleHostSpy()
        coordinator.attach(titleHost: host)

        coordinator.focusedSurfaceTitleDidChange(tabId: tab.id)

        #expect(tab.appliedProcessTitles.isEmpty)
        #expect(host.windowTitleRefreshWorkspaceIds.isEmpty)
    }
}
