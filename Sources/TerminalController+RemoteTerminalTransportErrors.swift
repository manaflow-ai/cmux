import CmuxCore
import CmuxControlSocket
import CmuxFoundation
import Foundation

extension TerminalController {
    func remoteTerminalProfileConfiguration(
        _ params: [String: Any]
    ) -> (profile: WorkspaceRemoteTerminalProfile, error: ControlCallResult?) {
        guard let profile = WorkspaceRemoteTerminalProfile(
            remoteConfigurationValue: v2RawString(params, "terminal_profile"),
            tmuxSessionName: v2RawString(params, "terminal_tmux_session")
        ) else {
            return (.shell, invalidRemoteTerminalProfileResult())
        }
        return (profile, nil)
    }

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
                defaultValue: "The remote terminal transport must be SSH or Mosh."
            ),
            data: nil
        )
    }

    func invalidRemoteTerminalProfileResult() -> ControlCallResult {
        .err(
            code: "invalid_params",
            message: String(
                localized: "socket.workspace.remote.terminalProfile.invalid",
                defaultValue: "The remote terminal must open a shell or a valid named tmux session."
            ),
            data: nil
        )
    }

    func unsupportedMoshRemoteTerminalTransportResult() -> ControlCallResult {
        .err(
            code: "invalid_params",
            message: String(
                localized: "socket.workspace.remote.terminalTransport.moshRequiresSSH",
                defaultValue: "Mosh terminal transport requires an SSH-managed workspace."
            ),
            data: nil
        )
    }
}
