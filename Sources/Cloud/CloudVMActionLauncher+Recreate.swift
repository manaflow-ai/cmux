import AppKit
import CmuxSettings

/// Shared Recreate action used by machine menus and pane failure cards.
@MainActor
extension CloudVMActionLauncher {
    func recreate(
        machineID: String,
        preferredWindow: NSWindow?,
        onCompletion: (@MainActor (Completion) -> Void)? = nil
    ) {
        let socketPath = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        _ = start(
            socketPath: socketPath,
            preferredWindow: preferredWindow,
            arguments: ["vm", "fork", machineID],
            successTitle: String(localized: "cloudPane.recreate.success", defaultValue: "Machine recreated"),
            presentsFailureAlert: true,
            onCompletion: onCompletion
        )
    }
}
