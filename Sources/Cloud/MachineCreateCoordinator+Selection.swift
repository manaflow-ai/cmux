import Foundation

extension MachineCreateCoordinator {
    /// Selects the receipt in the initiating window without activating it.
    func selectCreatedWorkspace(_ workspaceID: UUID, for request: MachineCreateRequest) {
        guard let windowID = request.selectionWindowID,
              let manager = AppDelegate.shared?.tabManagerFor(windowId: windowID),
              let workspace = manager.tabs.first(where: { $0.id == workspaceID }) else { return }
        manager.selectWorkspace(workspace)
    }
}
