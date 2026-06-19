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
    private(set) var shellActivityUpdates: [(panelId: UUID, state: PanelShellActivityState)] = []

    init(id: UUID = UUID(), title: String = "") {
        self.id = id
        self.groupId = nil
        self.isPinned = false
        self.currentDirectory = "/tmp"
        self.title = title
    }

    func updatePanelShellActivityState(panelId: UUID, state: PanelShellActivityState) {
        shellActivityUpdates.append((panelId, state))
    }
    func setCustomColor(_ hex: String?) {}
}

@MainActor
struct SurfaceMetadataCoordinatorTests {
    private func makeCoordinator(
        _ tabs: [MetadataStubTab]
    ) -> (SurfaceMetadataCoordinator<MetadataStubTab>, WorkspacesModel<MetadataStubTab>) {
        let model = WorkspacesModel<MetadataStubTab>()
        model.tabs = tabs
        return (SurfaceMetadataCoordinator(model: model), model)
    }

    @Test
    func titleForTabReturnsTheMatchingWorkspaceTitle() {
        let tab = MetadataStubTab(title: "feat-x")
        let (coordinator, _) = makeCoordinator([MetadataStubTab(title: "other"), tab])

        #expect(coordinator.titleForTab(tab.id) == "feat-x")
    }

    @Test
    func titleForTabReturnsNilForUnknownWorkspace() {
        let (coordinator, _) = makeCoordinator([MetadataStubTab(title: "a")])

        #expect(coordinator.titleForTab(UUID()) == nil)
    }

    @Test
    func applyShellActivityMutatesOwningWorkspaceAndReportsRefreshOnPromptIdle() {
        let tab = MetadataStubTab()
        let (coordinator, _) = makeCoordinator([tab])
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
        let (coordinator, _) = makeCoordinator([tab])
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
        let (coordinator, _) = makeCoordinator([present])

        let shouldRefresh = coordinator.applySurfaceShellActivity(
            tabId: UUID(),
            surfaceId: UUID(),
            state: .promptIdle
        )

        #expect(!shouldRefresh)
        #expect(present.shellActivityUpdates.isEmpty)
    }
}
