import Foundation

@MainActor
extension Workspace {
    var contextManagementOwner: AgentContextManagementCoordinator.PanelOwner { .workspace(self) }
}
