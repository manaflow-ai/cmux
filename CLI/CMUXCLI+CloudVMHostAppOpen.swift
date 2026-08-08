import CmuxFoundation
import Foundation

extension CMUXCLI {
    /// Asks the Mac app to open a Cloud VM workspace on its own machine.
    ///
    /// Used when this CLI is talking to cmux through the remote CLI relay: the
    /// socket RPCs land on the Mac but this process, its executable path, and
    /// anything it writes live on the remote host, so it cannot build the
    /// startup command the Mac-side pane has to run.
    func openCloudVMOnHostApp(
        id: String,
        workspaceName: String?,
        forceSSH: Bool,
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let command = hostAppCloudVMOpenCommand(
            id: id,
            workspaceName: workspaceName,
            forceSSH: forceSSH
        )
        do {
            let response = try client.sendV2(
                method: CloudVMHostAppOpenCommand.method,
                params: command.socketParameters,
                responseTimeout: Self.vmAttachResponseTimeoutSeconds
            )
            if jsonOutput {
                print(jsonString(response))
                return
            }
            print(String(
                localized: "cli.vm.open.delegatedToHostApp",
                defaultValue: "Opening the Cloud VM workspace on your Mac. Switch to the cmux window to use it."
            ))
        } catch let error as CLIError {
            guard error.v2Code == "method_not_found" else { throw error }
            throw CLIError(message: """
                This cmux app is too old to open a Cloud VM workspace from inside a remote session.

                What to do:
                  Update the cmux app on your Mac, then retry this command.
                  Until then, open the workspace from the Mac: New Workspace ▸ Open Base.

                Details:
                  The app does not support `\(CloudVMHostAppOpenCommand.method)`.
                """)
        }
    }

    /// A relayed caller names which attach it wants; the app owns argv.
    func hostAppCloudVMOpenCommand(
        id: String,
        workspaceName: String?,
        forceSSH: Bool
    ) -> CloudVMHostAppOpenCommand {
        if workspaceName == Self.persistentCloudVMWorkspaceName {
            return .base
        }
        return forceSSH ? .ssh(vmID: id) : .shell(vmID: id)
    }
}
