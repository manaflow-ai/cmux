import Foundation

extension MachineCreateCoordinator {
    func selectCreatedWorkspace(_ workspaceID: UUID, for request: MachineCreateRequest) {
        guard request.selectsCreatedWorkspace,
              let windowID = request.selectionWindowID,
              let manager = AppDelegate.shared?.tabManagerFor(windowId: windowID),
              let workspace = manager.tabs.first(where: { $0.id == workspaceID }) else { return }
        manager.selectWorkspace(workspace)
    }
}
