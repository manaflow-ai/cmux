import AppKit
import CmuxFoundation
import CmuxSettings
import Foundation

extension TerminalController {
    enum CloudVMHostAppOpenOutcome: Equatable {
        case started(workspaceID: UUID?)
        case failed(message: String)
    }

    /// Runs a Cloud VM attach on the Mac on behalf of a relayed CLI caller.
    ///
    /// `.base` goes through `performCloudVMAction`, the same workspace-owning
    /// action the New Workspace menu and titlebar button use, so Base keeps its
    /// loading panel, pinning, and reattach-to-existing behavior regardless of
    /// which entrypoint asked for it. The per-VM cases spawn the bundled CLI
    /// against the app's own socket, which is exactly what the relayed CLI
    /// could not do from the remote host.
    @MainActor
    static func startCloudVMOpenOnHostApp(_ command: CloudVMHostAppOpenCommand) -> CloudVMHostAppOpenOutcome {
        guard let appDelegate = AppDelegate.shared else {
            return .failed(message: "cmux is not ready to open a Cloud VM yet. Bring the cmux window to the front and try again.")
        }

        guard let arguments = command.cliArguments else {
            let didStart = appDelegate.performCloudVMAction(debugSource: "socket.vm.open_local.base")
            return didStart
                ? .started(workspaceID: nil)
                : .failed(message: "cmux could not open Base on this Mac. Open the New Workspace menu and choose Open Base to see the failure.")
        }

        let socketPath = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        let didStart = CloudVMActionLauncher.shared.start(
            socketPath: socketPath,
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow,
            arguments: arguments,
            showsProgress: false,
            presentsFailureAlert: true
        )
        return didStart
            ? .started(workspaceID: nil)
            : .failed(message: "cmux could not launch the Cloud VM attach on this Mac. Reload cmux so the bundled CLI is available, then retry.")
    }
}
