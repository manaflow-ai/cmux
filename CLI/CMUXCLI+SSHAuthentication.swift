import Foundation
import Darwin
import CmuxFoundation

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
    func runInteractiveAuthSSH(sshArgv: [String], destination: String, passwordCredential: String? = nil) throws {
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
        process.environment = SSHLocaleEnvironment().sanitized(ProcessInfo.processInfo.environment)
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
