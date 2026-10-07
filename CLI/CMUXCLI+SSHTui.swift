import CmuxFoundation
import Foundation

extension CMUXCLI {
    /// Removes only the exact cmux socket that CLI route resolution generated.
    /// The app recomputes its agent-aware route from the durable SSH options;
    /// caller-owned ControlPath values remain authoritative and are forwarded.
    static func sshOptionsForTUI(_ options: [String], routeIdentifier: String? = nil) -> [String] {
        let sharingOptions = SSHConnectionSharingOptions()
        var tuiOptions = options
        let generatedControlPath = sharingOptions.cmuxOwnedControlPath(in: tuiOptions)
        if generatedControlPath != nil {
            let resolver = SSHAgentSocketResolver(environment: [:])
            tuiOptions.removeAll { resolver.optionKey($0) == "controlpath" }
        }
        // A route digest is needed only when the generated socket was already
        // route-specific. The normal `%C` socket is recomputed by the app;
        // carrying its digest would unnecessarily split ordinary connections.
        if let routeIdentifier, generatedControlPath?.contains("%") == false,
           let routeMarker = sharingOptions.routeSensitiveOption(for: routeIdentifier) {
            tuiOptions.append(routeMarker)
        }
        return tuiOptions
    }

    /// SSH is only the carrier; the app projects the daemon-owned terminal natively.
    func runSSHTui(
        options: SSHCommandOptions,
        configuredRemoteCommand: String?,
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        routeIdentifier: String? = nil
    ) throws {
        var params: [String: Any] = [
            "destination": options.destination,
            "ssh_options": Self.sshOptionsForTUI(options.sshOptions, routeIdentifier: routeIdentifier),
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
