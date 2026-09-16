import Foundation

@MainActor
extension Workspace {
    /// The selected pane wins in mixed workspaces. Pending panes and a Cloud
    /// workspace binding retain that ownership while catalog state is unavailable.
    func cloudTerminalCreationTarget(for panelID: UUID?) -> CloudTerminalCreationTarget? {
        let catalog = SurfaceCatalog.shared
        if let panelID, let projection = catalog.projection(forPanel: panelID),
           projection.workspaceID == id, !projection.resource.machine.isLocal {
            return CloudTerminalCreationTarget(machine: projection.resource.machine, source: .projection(projection))
        }
        if let panelID, let pending = cloudPendingCreations[panelID] {
            return CloudTerminalCreationTarget(machine: pending.machine, source: .pending(pending))
        }
        if let binding = cloudVMBinding {
            return CloudTerminalCreationTarget(machine: .cloud(binding.vmID), source: .workspace(binding))
        }
        return nil
    }
}
