import Foundation
import Darwin

extension CMUXCLI {
    /// Runs an `ssh` argv interactively in the user's terminal so password /
    /// host-key / MFA / FIDO prompts work as in a normal SSH. The spawned ssh is
    /// made the terminal's foreground process group (Foundation otherwise spawns it
    /// backgrounded, where its tty read would be SIGTTIN-stopped and hang with no
    /// prompt).
    ///
    /// The argv is supplied by the app over the authenticated control socket, but
    /// as defense in depth the executable is required to be an `ssh` binary — the
    /// CLI never execs an arbitrary command handed back from a socket response.
    func runInteractiveAuthSSH(
        sshArgv: [String],
        destination: String,
        passwordCredential: String? = nil,
        marksRemoteTmuxAuthentication: Bool = false
    ) throws {
        // Interactive auth needs a controlling tty to prompt on. In a non-tty
        // context (script, pipe, URL handler) ssh can't prompt and would hang or
        // fail opaquely, so refuse early with an actionable message.
        guard isatty(STDIN_FILENO) == 1 || passwordCredential != nil else {
            throw CLIError(
                message: String(localized: "cli.ssh.authenticationNeedsTerminal", defaultValue: "SSH authentication requires a terminal. Run this command from an interactive shell.")
            )
        }
        // The app builds this argv with a hardcoded /usr/bin/ssh; require exactly
        // that. A basename check would accept a planted /tmp/ssh — pin the full
        // path so the CLI never execs an arbitrary command returned over the socket.
        let allowedSSHPaths: Set<String> = ["/usr/bin/ssh"]
        guard let executable = sshArgv.first, allowedSSHPaths.contains(executable) else {
            throw CLIError(message: String(localized: "cli.ssh.authenticationSystemExecutableRequired", defaultValue: "SSH authentication requires the system SSH executable."))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(sshArgv.dropFirst())
        var credentialDirectory: URL?
        defer { if let credentialDirectory { try? FileManager.default.removeItem(at: credentialDirectory) } }
        if let passwordCredential {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-ssh-auth-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            credentialDirectory = directory
            let password = directory.appendingPathComponent("password")
            try Data(passwordCredential.utf8).write(to: password, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: password.path)
            let script = directory.appendingPathComponent("authenticate.sh")
            try sshAskpassExecShellScript(passwordFilePath: password.path, cleanupDirectory: directory.path)
                .write(to: script, atomically: true, encoding: .utf8)
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path] + sshArgv
        }
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        if marksRemoteTmuxAuthentication {
            // Mark this ssh as cmux's interactive login. It pins cmux's own ControlPath, so a
            // site's ssh_config hooks (Match exec ProxyCommand/2FA helpers) that would normally
            // skip work when the user's own shared master is live can see that this connection
            // cannot ride that master and still needs a full authentication.
            var environment = ProcessInfo.processInfo.environment
            environment["CMUX_REMOTE_TMUX_AUTH"] = "1"
            process.environment = environment
        }

        // Foundation spawns the child in its OWN process group, so ssh starts as a
        // BACKGROUND job of the terminal. ssh's password / host-key / MFA prompt
        // reads from the controlling tty, and a background tty read raises SIGTTIN,
        // which STOPS ssh — it hangs forever with no prompt (cert/agent hosts never
        // read the tty, so they were unaffected). Hand the terminal's foreground
        // process group to the child (and SIGCONT it in case it already stopped) so
        // it can prompt, exactly as the other interactive-child CLI paths do; the
        // `defer` reclaims the foreground for this CLI when ssh exits.
        let originalForegroundProcessGroup = tcgetpgrp(STDIN_FILENO)
        var didForegroundChild = false
        do {
            try cliRunProcess(process)
        } catch {
            throw CLIError(message: String(format: String(localized: "cli.ssh.authenticationLaunchFailed", defaultValue: "Could not launch SSH: %@"), String(describing: error)))
        }
        if originalForegroundProcessGroup > 0 {
            let childProcessGroup = getpgid(process.processIdentifier)
            if childProcessGroup > 0 && childProcessGroup != originalForegroundProcessGroup {
                do {
                    try setTerminalForegroundProcessGroup(childProcessGroup)
                } catch {
                    // The handoff is required: without the terminal foreground, ssh's
                    // prompt SIGTTIN-stops and waitUntilExit() below hangs forever (the
                    // exact bug this dance prevents). Continue the child in case it
                    // already stopped, kill it, and fail loudly instead of hanging.
                    _ = Darwin.kill(-childProcessGroup, SIGCONT)
                    process.terminate()
                    throw CLIError(
                        message: String(format: String(localized: "cli.ssh.authenticationForegroundFailed", defaultValue: "Could not hand the terminal to SSH for %@. Authentication was cancelled to avoid a hang (%@)."), destination, String(describing: error))
                    )
                }
                _ = Darwin.kill(-childProcessGroup, SIGCONT)
                didForegroundChild = true
            }
        }
        defer {
            if didForegroundChild {
                try? setTerminalForegroundProcessGroup(originalForegroundProcessGroup)
            }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIError(
                message: String(format: String(localized: "cli.ssh.authenticationExitFailed", defaultValue: "SSH authentication to %@ failed (exit %@)."), destination, String(process.terminationStatus))
            )
        }
    }

}

/// Prints where a remote tmux attach stands while the request that started it waits.
///
/// The attach request is one call that answers when the attach is over, and a login that
/// needs a tap or queues behind another connection can take minutes. This asks the app on a
/// second connection which phase the attach is in, and prints a line when the phase changes
/// and every 15 seconds while it does not, so a long login reads as one that is still running.
final class RemoteTmuxAttachProgressReporter: @unchecked Sendable {
    private let socketPath: String
    private let params: [String: Any]
    private let stopRequested = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)

    init(socketPath: String, params: [String: Any]) {
        self.socketPath = socketPath
        self.params = params
    }

    func start() {
        Thread.detachNewThread { [self] in
            defer { finished.signal() }
            let client = SocketClient(path: socketPath)
            guard (try? client.connect()) != nil else { return }
            defer { client.close() }
            var lastPhase: String?
            var lastPrintedAt = Date.distantPast
            // The semaphore is the stop signal, so stopping ends this wait at once.
            while stopRequested.wait(timeout: .now() + 2) == .timedOut {
                guard let result = try? client.sendV2(
                    method: "remote.tmux.attach_progress", params: params, responseTimeout: 5),
                    (result["attaching"] as? Bool) == true,
                    let phase = result["phase"] as? String
                else { continue }
                guard phase != lastPhase || Date().timeIntervalSince(lastPrintedAt) >= 15 else { continue }
                lastPhase = phase
                lastPrintedAt = Date()
                print(Self.line(
                    phase: phase,
                    quietSeconds: (result["quiet_seconds"] as? Int) ?? 0,
                    quietLimitSeconds: (result["quiet_limit_seconds"] as? Int) ?? 0))
                fflush(stdout)
            }
        }
    }

    /// Ends the reporting. Waits briefly for a line in flight so it cannot land after the result.
    func stop() {
        stopRequested.signal()
        _ = finished.wait(timeout: .now() + 1)
    }

    static func line(phase: String, quietSeconds: Int, quietLimitSeconds: Int) -> String {
        if phase == "in_tmux" {
            return "  tmux answered; reading its sessions"
        }
        return "  still logging in: the connection is running and has been quiet for "
            + "\(quietSeconds) s (cmux stops waiting at \(quietLimitSeconds) s)"
    }
}
