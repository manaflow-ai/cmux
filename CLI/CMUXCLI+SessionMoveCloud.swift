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
        Self.removeStaleSessionMoveKeyFolders()
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
                options: Self.sessionMoveCloudSSHOptions(knownHosts: knownHosts.path),
                configFile: "/dev/null"
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

    /// Removes key folders a killed move left behind (a signal skips `defer`).
    /// Their grants expired long before an hour passed.
    static func removeStaleSessionMoveKeyFolders(now: Date = Date()) {
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory
        guard let names = try? fileManager.contentsOfDirectory(atPath: temporary.path) else { return }
        for name in names where name.hasPrefix("cmux-session-move-") {
            let folder = temporary.appendingPathComponent(name, isDirectory: true)
            guard let modified = (try? fileManager.attributesOfItem(atPath: folder.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > 3600 else { continue }
            try? fileManager.removeItem(at: folder)
        }
    }

    /// The same pinned, key-only, no-agent options `cmux vm push` uses. With
    /// `ssh -F /dev/null` (the target's `configFile`) the user's ssh_config
    /// cannot redirect, proxy or forward the grant; the host key alias and the
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

    /// Exit status of a Cloud move that failed after the session data reached
    /// the machine: the conversation now lives there (its terminal may even have
    /// started), so the app must not resume it on this Mac.
    static let sessionMoveCloudUnfinishedExitCode: Int32 = 3

    /// A failure after the move: the record already says `cloud:<machine>`.
    /// Any other destination keeps the error as it was.
    func sessionMoveCloudUnfinished(_ error: Error, machine: String?, sessionID: String, workingDirectory: String) -> Error {
        guard let machine else { return error }
        return CLIError(
            message: String(
                format: String(
                    localized: "cli.session.move.error.cloudTerminal",
                    defaultValue: "session move: the conversation moved to Cloud machine %@, but its terminal did not open (%@). Open a terminal on that machine and run `claude --resume %@` in %@."
                ),
                machine,
                String(describing: error),
                sessionID,
                workingDirectory
            ),
            exitCode: Self.sessionMoveCloudUnfinishedExitCode
        )
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
