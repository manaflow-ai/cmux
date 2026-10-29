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

    /// Parses the optional `terminal_et_options` object
    /// (`port`, `terminal_path`, `tunnels`, `reverse_tunnels`).
    func remoteEternalTerminalConfiguration(
        _ params: [String: Any]
    ) -> (options: EternalTerminalOptions, error: ControlCallResult?) {
        guard v2HasNonNullParam(params, "terminal_et_options") else { return (.default, nil) }
        guard let raw = params["terminal_et_options"] as? [String: Any] else {
            return (.default, invalidRemoteEternalTerminalOptionsResult())
        }
        var port: Int?
        if v2HasNonNullParam(raw, "port") {
            guard let parsed = v2StrictInt(raw, "port") else {
                return (.default, invalidRemoteEternalTerminalOptionsResult())
            }
            port = parsed
        }
        // A present value of the wrong type is an error, not an omitted option.
        var terminalPath: String?
        if v2HasNonNullParam(raw, "terminal_path") {
            guard let parsed = raw["terminal_path"] as? String else {
                return (.default, invalidRemoteEternalTerminalOptionsResult())
            }
            terminalPath = parsed
        }
        var tunnelLists: [[String]] = []
        for key in ["tunnels", "reverse_tunnels"] {
            guard v2HasNonNullParam(raw, key) else {
                tunnelLists.append([])
                continue
            }
            guard let parsed = raw[key] as? [String] else {
                return (.default, invalidRemoteEternalTerminalOptionsResult())
            }
            tunnelLists.append(parsed)
        }
        guard let options = EternalTerminalOptions(
            serverPort: port,
            terminalPath: terminalPath,
            tunnels: tunnelLists[0],
            reverseTunnels: tunnelLists[1]
        ) else {
            return (.default, invalidRemoteEternalTerminalOptionsResult())
        }
        return (options, nil)
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
                defaultValue: "The remote terminal transport must be SSH, Mosh, or Eternal Terminal."
            ),
            data: nil
        )
    }

    func invalidRemoteEternalTerminalOptionsResult() -> ControlCallResult {
        .err(
            code: "invalid_params",
            message: String(
                localized: "socket.workspace.remote.terminalTransport.etOptionsInvalid",
                defaultValue: "Use ports 1-65535, non-empty values without control characters, an absolute terminal path, and compatible tunnel pairs or equal-length port ranges. Use SSH tunnel syntax only for a single tunnel."
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
                defaultValue: "Mosh and Eternal Terminal transports require an SSH-managed workspace."
            ),
            data: nil
        )
    }
}
