import CmuxNextActions
import CmuxNextDaemon
import Foundation
import CmuxNextRemote
import CmuxNextWakeups

/// The confirmation of Install cmux-tui on an SSH machine (Forget has an
/// undo toast instead, `RemoteForgetUndo`).
enum RemoteConfirmation {
    static func prompt(for id: ActionID, _ invocation: ActionInvocation, _ context: AppActionContext) async -> DestructiveConfirmation.Prompt? {
        guard id == "remote.install", let session = try? RemoteHandlers.machine(invocation, context) else { return nil }
        let host = session.host
        var commit = "?"
        if let binary = try? DaemonLauncherBinary.resolve() { commit = await BundledCmuxTUI.commit(binary: binary, on: context.services.work).map { String($0.prefix(12)) } ?? "?" }
        if session.updateOffered {
            return DestructiveConfirmation.Prompt(
                title: RemoteStrings.updateTitle(host.label),
                body: RemoteStrings.updateBody(commit: commit, path: host.remoteBinary, machine: host.label),
                button: RemoteStrings.update)
        }
        return DestructiveConfirmation.Prompt(
            title: RemoteStrings.installTitle(host.label),
            body: RemoteStrings.installBody(commit: commit, path: host.remoteBinary, destination: host.destination.description)
                + (RemoteStrings.detail(session).map { "\n\n" + $0 } ?? ""),
            button: RemoteStrings.install)
    }
}

/// The bundled cmux-tui (`CMUX_NEXT_TUI_BIN`, else the app's own).
enum DaemonLauncherBinary {
    static func resolve() throws -> URL {
        try DaemonLauncher.resolveBinary(bundle: .main, environment: ProcessInfo.processInfo.environment)
    }
}
