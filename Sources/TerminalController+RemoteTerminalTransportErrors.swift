import CmuxCore
import CmuxControlSocket
import Foundation

extension TerminalController {
    func remoteTransportConfiguration(
        _ params: [String: Any]
    ) -> (
        management: WorkspaceRemoteTransport,
        terminal: WorkspaceRemoteTerminalTransport,
        skipDaemonBootstrap: Bool,
        error: ControlCallResult?
    ) {
        let management = WorkspaceRemoteTransport(
            remoteConfigurationValue: v2RawString(params, "transport")
        )
        let skipDaemonBootstrap = v2Bool(params, "skip_daemon_bootstrap") ?? false
        guard let terminal = WorkspaceRemoteTerminalTransport(
            remoteConfigurationValue: v2RawString(params, "terminal_transport")
        ) else {
            return (management, .ssh, skipDaemonBootstrap, invalidRemoteTerminalTransportResult())
        }
        guard terminal.isSupportedForRemoteConfiguration(
            managementTransport: management,
            skipDaemonBootstrap: skipDaemonBootstrap
        ) else {
            return (management, terminal, skipDaemonBootstrap, unsupportedMoshRemoteTerminalTransportResult())
        }
        return (management, terminal, skipDaemonBootstrap, nil)
    }

    func invalidRemoteTerminalTransportResult() -> ControlCallResult {
        .err(
            code: "invalid_params",
            message: String(
                localized: "socket.workspace.remote.terminalTransport.invalid",
                defaultValue: "terminal_transport must be 'ssh' or 'mosh'"
            ),
            data: nil
        )
    }

    func unsupportedMoshRemoteTerminalTransportResult() -> ControlCallResult {
        .err(
            code: "invalid_params",
            message: String(
                localized: "socket.workspace.remote.terminalTransport.moshRequiresSSH",
                defaultValue: "terminal_transport 'mosh' requires an SSH-managed workspace with daemon bootstrap"
            ),
            data: nil
        )
    }
}
