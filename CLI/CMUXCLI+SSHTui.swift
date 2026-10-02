import CmuxFoundation
import Foundation

extension CMUXCLI {
    /// `--here` never resolves a missing or stale caller into the focused workspace.
    /// The app validates ownership again after its asynchronous SSH preflight.
    func sshHereCallerContext(options: SSHCommandOptions) throws -> (workspaceID: String, surfaceID: String)? {
        guard options.reuseCurrentPane else { return nil }
        guard options.windowRaw == nil else {
            throw CLIError(message: String(localized: "cli.ssh.here.windowConflict", defaultValue: "ssh --here uses the current pane and cannot be combined with --window."))
        }
        guard options.terminalTransport == .ssh,
              !options.remoteCommand.disablesTTY(in: options.sshOptions) else {
            throw sshHereRequiresInteractiveSSH()
        }
        let environment = ProcessInfo.processInfo.environment
        guard let workspace = environment["CMUX_WORKSPACE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let surface = environment["CMUX_SURFACE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              UUID(uuidString: workspace) != nil,
              UUID(uuidString: surface) != nil else {
            throw CLIError(message: String(localized: "cli.ssh.here.requiresPane", defaultValue: "ssh --here must be run from an active cmux terminal pane."))
        }
        return (workspace, surface)
    }

    func sshHereRequiresInteractiveSSH() -> CLIError {
        CLIError(message: String(localized: "cli.ssh.here.requiresInteractiveSSH", defaultValue: "ssh --here requires interactive SSH. Remove --transport mosh and options that disable a terminal."))
    }

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
        if let caller = try sshHereCallerContext(options: options) {
            guard let process = AgentPIDProcessIdentity(pid: ProcessInfo.processInfo.processIdentifier) else {
                throw CLIError(message: String(localized: "cli.ssh.here.callerUnavailable", defaultValue: "ssh --here could not verify the calling process. Run it again from the terminal pane."))
            }
            params["here"] = true
            params["workspace_id"] = caller.workspaceID
            params["surface_id"] = caller.surfaceID
            params["caller_process"] = [
                "pid": process.pid,
                "start_seconds": process.startSeconds,
                "start_microseconds": process.startMicroseconds,
            ]
        } else {
            try applyWindowOrCallerContext(to: &params, client: client, windowRaw: options.windowRaw)
        }
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
            let hereVisit: (workspaceID: String, operationID: String)?
            if options.reuseCurrentPane {
                guard let caller = try sshHereCallerContext(options: options),
                      let operationID = response["here_operation_id"] as? String,
                      UUID(uuidString: operationID) != nil else {
                    throw CLIError(message: String(localized: "cli.ssh.here.missingSession", defaultValue: "ssh --here did not receive an in-place session identity from cmux."))
                }
                hereVisit = (caller.workspaceID, operationID)
            } else {
                hereVisit = nil
            }
            printV2Payload(response, jsonOutput: jsonOutput, idFormat: idFormat,
                           fallbackText: v2CreationSummary(response, idFormat: idFormat, kinds: ["workspace", "surface"]))
            if let hereVisit {
                // Preserve SSH's foreground lifetime: the caller's shell must
                // not run its next command while it is parked behind the remote
                // pane. Compare this visit's ID, not just connected status;
                // transient SSH reconnects do not finish an in-place visit.
                while true {
                    do {
                        try client.connect()
                        let status = try client.sendV2(method: "workspace.remote.status", params: [
                            "workspace_id": hereVisit.workspaceID,
                        ])
                        if let remote = status["remote"] as? [String: Any], remote["enabled"] is Bool {
                            let activeID = remote["here_operation_id"] as? String
                            if activeID?.caseInsensitiveCompare(hereVisit.operationID) != .orderedSame { break }
                        }
                    } catch {
                        // Losing the control socket does not establish that the
                        // hidden local shell has been restored. Reconnect and
                        // keep waiting instead of running a chained local command.
                        cliDebugLog("cli.ssh.here.status_retry error=\(error)")
                        client.close()
                        Thread.sleep(forTimeInterval: 1)
                        continue
                    }
                    Thread.sleep(forTimeInterval: 0.25)
                }
            }
            return
        }
    }
}
