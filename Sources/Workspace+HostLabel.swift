import CmuxFoundation
import Foundation

extension Workspace {
    /// Where this workspace runs, derived from its Cloud machine or SSH
    /// destination, never from the title the user typed.
    ///
    /// Window titles and the Task Manager read this one value so they name a
    /// remote workspace's host the same way.
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
                port: remoteConfiguration.port ?? Self.sshOptionPort(remoteConfiguration.sshOptions)
            ) ?? .local
        }
        return .local
    }

    /// A port set through `--ssh-option Port=...`, which `cmux ssh` accepts in
    /// place of `-p`.
    private static func sshOptionPort(_ options: [String]) -> Int? {
        SSHAgentSocketResolver(environment: [:]).optionValue(named: "Port", in: options).flatMap(Int.init)
    }
}
