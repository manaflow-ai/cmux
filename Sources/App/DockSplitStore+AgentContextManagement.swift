import Foundation

@MainActor
extension DockSplitStore {
    var contextManagementOwner: AgentContextManagementCoordinator.PanelOwner { .dock(self) }
}
