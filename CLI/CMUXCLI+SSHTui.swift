import CmuxFoundation
import Foundation

extension CMUXCLI {
    /// SSH is only the carrier; the app projects the daemon-owned terminal natively.
    func runSSHTui(
        options: SSHCommandOptions,
        configuredRemoteCommand: String?,
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        var params: [String: Any] = [
            "destination": options.destination,
            "ssh_options": options.sshOptions,
            "focus": !options.noFocus,
            "operation_id": UUID().uuidString.lowercased(),
        ]
        if let port = options.port { params["port"] = port }
        if let identity = options.identityFile { params["identity_file"] = identity }
        if let name = options.workspaceName { params["title"] = name }
        if let agent = options.agentSocketPath { params["ssh_auth_sock"] = agent }
        if let configuredRemoteCommand { params["configured_remote_command"] = configuredRemoteCommand }
        if let initialCommand = options.initialCommand { params["initial_command"] = initialCommand }
        if !options.remoteCommand.arguments.isEmpty {
            params["initial_command"] = options.remoteCommand.arguments.joined(separator: " ")
        }
        params["terminal_profile"] = options.terminalProfile.kind.rawValue
        if let session = options.terminalProfile.tmuxSessionName { params["terminal_tmux_session"] = session }
        try applyWindowOrCallerContext(to: &params, client: client, windowRaw: options.windowRaw)
        var authenticated = false
        while true {
            let response = try client.sendV2(method: "workspace.ssh.open", params: params, responseTimeout: 200)
            if response["auth_required"] as? Bool == true {
                guard !authenticated, let arguments = response["ssh_argv"] as? [String] else {
                    throw CLIError(message: String(localized: "cli.ssh.authenticationFailed", defaultValue: "SSH authentication did not open the connection. Check your SSH credentials and retry."))
                }
                try runInteractiveAuthSSH(sshArgv: arguments, destination: options.destination, passwordCredential: options.passwordCredential)
                authenticated = true
                continue
            }
            printV2Payload(response, jsonOutput: jsonOutput, idFormat: idFormat,
                           fallbackText: v2CreationSummary(response, idFormat: idFormat, kinds: ["workspace", "surface"]))
            return
        }
    }
}
