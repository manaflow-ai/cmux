import CMUXAgentLaunch
import Foundation

/// `cmux session move <id> --to cloud[:<machine>]`: the same move as an SSH
/// host, over a short-lived SSH grant into the Cloud machine (`vm.scp_info`:
/// an ephemeral key, the machine's verified host key pinned, 127.0.0.1 over the
/// app's private connection). The machine is picked as `cmux vm agent` picks
/// one. A fresh machine gets the checkout and cwd created.
extension CMUXCLI {
    /// A Cloud destination for one move. `directory` holds the key and
    /// known_hosts file and is removed when the move is done.
    struct SessionMoveCloudTarget {
        let machine: String
        let target: AgentMoveSSHTarget
        let directory: URL
    }

    /// `cloud` or `cloud:<machine>`; nil for any other destination.
    static func sessionMoveCloudMachine(_ name: String) -> String?? {
        if name == "cloud" { return .some(nil) }
        guard name.hasPrefix("cloud:") else { return nil }
        let machine = String(name.dropFirst("cloud:".count))
        return .some(machine.isEmpty ? nil : machine)
    }

    func sessionMoveCloudTarget(machine: String?, workDirectory: String, client: SocketClient) throws -> SessionMoveCloudTarget {
        let selection = try selectVMForRun(
            machineOverride: machine,
            forceNew: false,
            memoryMb: nil,
            workDirectory: workDirectory,
            client: client
        )
        cliWriteStderr(String(
            format: String(localized: "cli.session.move.progress.cloudMachine", defaultValue: "session move: Cloud machine %@ (%@)"),
            selection.id,
            selection.reason
        ) + "\n")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-session-move-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let identity = directory.appendingPathComponent("identity")
            let generated = CLIProcessRunner.runProcess(
                executablePath: "/usr/bin/ssh-keygen",
                arguments: ["-q", "-t", "ed25519", "-N", "", "-C", "cmux-session-move", "-f", identity.path],
                stdinText: "",
                timeout: 15
            )
            guard generated.status == 0 else {
                throw CLIError(message: String(localized: "cli.session.move.error.cloudKey", defaultValue: "session move: could not create the Cloud SSH key."))
            }
            let publicKey = try String(contentsOf: identity.appendingPathExtension("pub"), encoding: .utf8)
            let endpoint = try vmSCPTransferEndpoint(vmID: selection.id, publicKey: publicKey, client: client)
            let knownHosts = directory.appendingPathComponent("known_hosts")
            try ("cmux-scp " + endpoint.hostPublicKey + "\n").write(to: knownHosts, atomically: true, encoding: .utf8)
            let target = AgentMoveSSHTarget(
                destination: endpoint.destination,
                port: String(endpoint.port),
                identityFile: identity.path,
                options: Self.sessionMoveCloudSSHOptions(knownHosts: knownHosts.path)
            )
            guard target.isTransportSafe else {
                throw CLIError(message: String(
                    format: String(localized: "cli.session.move.error.cloudPath", defaultValue: "session move: the temporary folder %@ has a space in its path; set TMPDIR to a path without one."),
                    directory.path
                ))
            }
            return SessionMoveCloudTarget(machine: selection.id, target: target, directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// The same pinned, key-only, no-agent options `cmux vm push` uses. The
    /// user's ssh_config cannot redirect the grant: the host key alias and the
    /// known_hosts file are this move's own.
    static func sessionMoveCloudSSHOptions(knownHosts: String) -> [String] {
        [
            "StrictHostKeyChecking=yes",
            "HostKeyAlgorithms=ssh-ed25519",
            "HostKeyAlias=cmux-scp",
            "LogLevel=ERROR",
            "UserKnownHostsFile=" + knownHosts.replacingOccurrences(of: "%", with: "%%"),
            "GlobalKnownHostsFile=/dev/null",
            "IdentitiesOnly=yes",
            "PreferredAuthentications=publickey",
            "ControlMaster=no",
            "ControlPath=none",
            "ForwardAgent=no",
            "ServerAliveInterval=15",
            "ServerAliveCountMax=3",
        ]
    }

    /// Opens the resumed session as a terminal on the Cloud machine. Resumes the
    /// plain `claude` there: launcher paths recorded on this Mac do not exist on
    /// the machine.
    func openSessionMoveCloudTerminal(
        machine: String,
        sessionID: String,
        workingDirectory: String,
        permissionMode: String?,
        name: String,
        focus: Bool,
        client: SocketClient
    ) throws -> [String: Any] {
        let resume = agentSurfaceResumeCommand(
            kind: "claude",
            sessionId: sessionID,
            launchCommand: nil,
            workingDirectory: workingDirectory,
            environment: nil,
            observedPermissionMode: permissionMode
        ) ?? "cd \(shellQuote(workingDirectory)) && claude --resume \(sessionID)"
        let command = [
            "bash", "-lc",
            "export PATH=\"$HOME/.npm-global/bin:$HOME/.bun/bin:$HOME/.local/bin:$PATH\"; \(resume)",
        ]
        return try client.sendV2(method: "surface.new_terminal", params: [
            "machine": machine,
            "command": command,
            "name": name,
            "open": true,
            "focus": focus,
        ], responseTimeout: 240)
    }
}
