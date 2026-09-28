import CmuxFoundation
import Foundation

extension Workspace {
    /// Where this workspace runs, derived from its Cloud machine or SSH
    /// destination, never from the title the user typed.
    ///
    /// Window titles, the Task Manager and group-by-host read this one value
    /// so every surface names a remote workspace's host the same way.
    var hostLabel: WorkspaceHostLabel {
        if let machineID = cloudVMID {
            return WorkspaceHostLabel.cloud(
                machineID: machineID,
                machineName: cloudBindingState.machineNames[machineID]
            ) ?? .local
        }
        if let remoteConfiguration {
            return WorkspaceHostLabel.ssh(
                destination: remoteConfiguration.destination,
                port: remoteConfiguration.port
            ) ?? .local
        }
        return .local
    }
}
