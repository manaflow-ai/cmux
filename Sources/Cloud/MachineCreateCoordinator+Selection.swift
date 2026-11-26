import Foundation

extension MachineCreateCoordinator {
    @discardableResult
    static func selectCreatedWorkspace(_ workspaceID: UUID, for request: MachineCreateRequest) -> Bool {
        guard request.selectsCreatedWorkspace,
              let windowID = request.selectionWindowID,
              let manager = AppDelegate.shared?.tabManagerFor(windowId: windowID),
              let workspace = manager.tabs.first(where: { $0.id == workspaceID }) else { return false }
        manager.selectWorkspace(workspace)
        return true
    }
}
