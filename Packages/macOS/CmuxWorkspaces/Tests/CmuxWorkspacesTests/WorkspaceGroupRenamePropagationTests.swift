import Foundation
import Testing
import CmuxSettings
@testable import CmuxWorkspaces

@MainActor
@Suite("Workspace group rename propagation")
struct WorkspaceGroupRenamePropagationTests {
    @Test("Generated anchor rename is handed to the app host")
    func generatedAnchorRename() throws {
        let model = WorkspacesModel<RenamePropagationStubTab>()
        let host = RenamePropagationHost(model: model)
        let coordinator = WorkspaceGroupCoordinator(model: model)
        coordinator.attach(host: host)
        model.tabs = [RenamePropagationStubTab()]
        let groupID = try #require(coordinator.createWorkspaceGroup(
            name: "Before",
            selectAnchor: false,
            collapseSidebarSelection: false
        ))
        let anchorID = try #require(model.workspaceGroups.first?.liveAnchorWorkspaceId)

        coordinator.renameWorkspaceGroup(groupId: groupID, name: "After")

        #expect(host.generatedAnchorNameChanges.map { $0.0 } == [anchorID])
        #expect(host.generatedAnchorNameChanges.map { $0.1 } == ["After"])
        #expect(model.workspaceGroups.first?.name == "After")
    }

    @Test("User-promoted anchor is not overwritten by group rename")
    func userAnchorRemainsOwned() throws {
        let model = WorkspacesModel<RenamePropagationStubTab>()
        let host = RenamePropagationHost(model: model)
        let coordinator = WorkspaceGroupCoordinator(model: model)
        coordinator.attach(host: host)
        let member = RenamePropagationStubTab()
        model.tabs = [member]
        let groupID = try #require(coordinator.createWorkspaceGroup(
            name: "Before",
            childWorkspaceIds: [member.id],
            selectAnchor: false,
            collapseSidebarSelection: false
        ))

        coordinator.setWorkspaceGroupAnchor(groupId: groupID, workspaceId: member.id)
        coordinator.renameWorkspaceGroup(groupId: groupID, name: "After")

        #expect(host.generatedAnchorNameChanges.isEmpty)
        #expect(model.workspaceGroups.first?.name == "After")
    }
}

@MainActor
private final class RenamePropagationStubTab: WorkspaceTabRepresenting {
    let id = UUID()
    var groupId: UUID?
    var isPinned = false
    let currentDirectory = "/tmp"
}

@MainActor
private final class RenamePropagationHost: WorkspaceGroupHosting {
    typealias Tab = RenamePropagationStubTab

    let model: WorkspacesModel<RenamePropagationStubTab>
    var sidebarSelectedWorkspaceIds: Set<UUID> = []
    var defaultNewWorkspacePlacementInGroup: WorkspaceGroupNewPlacement { .end }
    var localizedAutoGroupNameFormat: String { "Group %lld" }
    var generatedAnchorNameChanges: [(UUID, String)] = []

    init(model: WorkspacesModel<RenamePropagationStubTab>) { self.model = model }
    func workspaceOrderDidChange(movedWorkspaceIds: [UUID]) {}
    func workspaceGroupNameDidChange() {}
    func normalizedGroupIconSymbol(_ symbol: String?) -> String? { symbol }
    func workspaceGroupGeneratedAnchorNameDidChange(_ anchor: RenamePropagationStubTab, name: String) {
        generatedAnchorNameChanges.append((anchor.id, name))
    }
    func selectWorkspace(_ tab: RenamePropagationStubTab) { model.selectedTabId = tab.id }
    func collapseSidebarSelectionForGroupCreation(hiddenWorkspaceIds: Set<UUID>, anchorId: UUID) {
        sidebarSelectedWorkspaceIds = [anchorId]
    }
    func subtractSidebarSelection(hiddenWorkspaceIds: Set<UUID>, focusedWorkspaceId: UUID?) {
        sidebarSelectedWorkspaceIds.subtract(hiddenWorkspaceIds)
    }
    func createGroupAnchorWorkspace(title: String, workingDirectory: String?, inheritWorkingDirectory: Bool, select: Bool) -> RenamePropagationStubTab? {
        let tab = RenamePropagationStubTab()
        model.tabs.insert(tab, at: 0)
        if select { model.selectedTabId = tab.id }
        return tab
    }
    func createWorkspaceForGroup(title: String?, workingDirectory: String?, initialSurface: NewWorkspaceInitialSurface, initialBrowserURL: URL?, initialBrowserOmnibarVisible: Bool, initialBrowserTransparentBackground: Bool, inheritWorkingDirectory: Bool, select: Bool, applyCreationTitleAsCustomTitle: Bool) -> RenamePropagationStubTab? {
        let tab = RenamePropagationStubTab()
        model.tabs.append(tab)
        if select { model.selectedTabId = tab.id }
        return tab
    }
    func closeWorkspaceForGroupDeletion(_ tab: RenamePropagationStubTab, recordHistory: Bool) {
        model.tabs.removeAll { $0.id == tab.id }
    }
}
