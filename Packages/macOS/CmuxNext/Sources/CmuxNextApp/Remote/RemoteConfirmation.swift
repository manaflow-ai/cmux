import CmuxNextActions
import CmuxNextDaemon
import Foundation
import CmuxNextRemote

/// The confirmation sheets of the destructive SSH machine actions.
enum RemoteConfirmation {
    static func prompt(for id: ActionID, _ invocation: ActionInvocation, _ context: AppActionContext) async -> DestructiveConfirmation.Prompt? {
        guard let session = try? RemoteHandlers.machine(invocation, context) else { return nil }
        let host = session.host
        switch id {
        case "remote.install":
            var commit = "?"
            if let binary = try? DaemonLauncherBinary.resolve() { commit = await BundledCmuxTUI.commit(binary: binary).map { String($0.prefix(12)) } ?? "?" }
            return DestructiveConfirmation.Prompt(
                title: RemoteStrings.installTitle(host.label),
                body: RemoteStrings.installBody(commit: commit, path: host.remoteBinary, destination: host.destination.description)
                    + (RemoteStrings.detail(session).map { "\n\n" + $0 } ?? ""),
                button: RemoteStrings.install)
        default:
            return DestructiveConfirmation.Prompt(title: RemoteStrings.forgetTitle(host.label), body: RemoteStrings.forgetBody,
                                                  button: RemoteStrings.forget)
        }
    }
}

/// The bundled cmux-tui (`CMUX_NEXT_TUI_BIN`, else the app's own).
enum DaemonLauncherBinary {
    static func resolve() throws -> URL {
        try DaemonLauncher.resolveBinary(bundle: .main, environment: ProcessInfo.processInfo.environment)
    }
}
