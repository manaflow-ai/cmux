import Foundation

/// Runs commands against a remote host's tmux server over a shared SSH
/// ControlMaster connection.
///
/// This is the non-interactive half of the remote-tmux feature: session
/// discovery (`tmux list-sessions`) and one-shot mutations (`new-session`,
/// `new-window`, `split-window`, `kill-*`, `send-keys`). The latency-sensitive
/// `tmux -CC` control stream is NOT run here — it runs in a ghostty surface so
/// it gets a PTY. Both share the same ControlMaster socket
/// (``RemoteTmuxHost/controlSocketPath``), so the first to connect authenticates
/// and the rest are subsecond.
///
/// Modeled as an `actor` because it owns the per-host connection lifecycle and
/// serializes process launches; reads/writes are `async`.
actor RemoteTmuxSSHTransport {
    private static let maxCapturedOutputBytes = 1_048_576

    /// The host this transport talks to.
    ///
    /// `nonisolated` so the controller can read it synchronously (it's an immutable
    /// `Sendable` value) when tearing down masters on quit/window-close.
    nonisolated let host: RemoteTmuxHost

    private let sshExecutablePath: String
    private let controlPersistSeconds: Int

    /// - Parameters:
    ///   - host: the remote destination.
    ///   - sshExecutablePath: the local `ssh` binary (overridable for tests).
    ///   - controlPersistSeconds: idle lifetime of the shared master.
    init(
        host: RemoteTmuxHost,
        sshExecutablePath: String = "/usr/bin/ssh",
        controlPersistSeconds: Int = 180
    ) {
        self.host = host
        self.sshExecutablePath = sshExecutablePath
        self.controlPersistSeconds = controlPersistSeconds
    }

    // MARK: - High-level tmux operations

    /// Lists the tmux sessions on the remote server.
    ///
    /// Returns an empty array when the remote tmux server is not running yet
    /// (cmux treats "no server running" / "no sessions" as zero sessions, not
    /// an error, so the sidebar can still offer to create one).
    func listSessions() async throws -> [RemoteTmuxSession] {
        let result = try await runTmux([
            "list-sessions", "-F", RemoteTmuxSessionListParser.formatString,
        ])
        if !result.succeeded {
            if Self.indicatesAuthRequired(result.stderr) {
                throw RemoteTmuxError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
            }
            if Self.indicatesNoServer(result.stderr) { return [] }
            throw RemoteTmuxError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        return RemoteTmuxSessionListParser.parse(result.stdout)
    }

    /// Runs a `tmux <args…>` command on the remote host and returns its result.
    @discardableResult
    func runTmux(_ args: [String]) async throws -> RemoteTmuxCommandResult {
        try await run(["tmux"] + args)
    }

    /// Runs an arbitrary remote command over the shared SSH master.
    ///
    /// `ssh` concatenates the post-destination argv with spaces and the remote
    /// login shell re-splits the result, so each remote token is single-quoted
    /// here; otherwise whitespace inside an argument (e.g. the tabs in a
    /// `list-sessions -F` format string) would be word-split on the remote.
    @discardableResult
    func run(_ remoteArgs: [String]) async throws -> RemoteTmuxCommandResult {
        try host.ensureControlSocketDirectory()
        let remoteCommand = remoteArgs
            .map { RemoteTmuxHost.shellSingleQuoted($0) }
            .joined(separator: " ")
        // `--` ends ssh option parsing so a destination beginning with `-`
        // (e.g. `-oProxyCommand=…`) can never be consumed as an ssh option.
        let sshArgs =
            host.sshControlArguments(controlPersistSeconds: controlPersistSeconds, batchMode: true)
            + ["--", host.destination, remoteCommand]
        return try await Self.runProcess(executable: sshExecutablePath, arguments: sshArgs)
    }

    // MARK: - Control-attach preflight

    /// Ensures the requested session is attachable via a non-interactive tmux
    /// command. Returns an auth-required outcome when BatchMode SSH cannot prompt;
    /// returns `nil` when the control stream may be launched.
    ///
    /// Runs the BatchMode probe over this transport's shared master so auth/session
    /// failures are reported synchronously instead of looking like a successful
    /// attach of the long-lived `tmux -CC` control stream.
    func preflightControlAttach(
        sessionName: String,
        createIfMissing: Bool
    ) async throws -> [String]? {
        do {
            let existing = try await runTmux(["has-session", "-t", sessionName])
            if existing.succeeded {
                return nil
            }
            if let sshArgv = authRequiredAttachArgv(result: existing) {
                return sshArgv
            }

            guard createIfMissing else {
                throw RemoteTmuxError.commandFailed(exitCode: existing.exitCode, stderr: existing.stderr)
            }

            let created = try await runTmux(["new-session", "-d", "-s", sessionName])
            guard created.succeeded else {
                if let sshArgv = authRequiredAttachArgv(result: created) {
                    return sshArgv
                }
                throw RemoteTmuxError.commandFailed(exitCode: created.exitCode, stderr: created.stderr)
            }
            return nil
        } catch let error as RemoteTmuxError {
            if case .commandFailed(_, let stderr) = error,
               Self.indicatesAuthRequired(stderr) {
                return host.interactiveAuthInvocation()
            }
            throw error
        }
    }

    /// Classifies a failed BatchMode tmux probe: returns the interactive `ssh`
    /// argv when stderr indicates the host needs interactive auth, otherwise `nil`.
    private func authRequiredAttachArgv(result: RemoteTmuxCommandResult) -> [String]? {
        guard !result.succeeded,
              Self.indicatesAuthRequired(result.stderr) else {
            return nil
        }
        return host.interactiveAuthInvocation()
    }

    /// Tears down the shared SSH master (e.g. when the user removes a host).
    func shutdownMaster() async {
        _ = try? await Self.runProcess(
            executable: sshExecutablePath,
            arguments: ["-O", "exit", "-o", "ControlPath=\(host.controlSocketPath)", "--", host.destination]
        )
    }

    /// Fire-and-forget `ssh -O exit` to close the host's shared SSH ControlMaster.
    ///
    /// `nonisolated` and non-`async` so it can run from the synchronous app-quit /
    /// window-close paths where awaiting an actor isn't possible. `-O exit` hits the
    /// LOCAL control socket (fast, no network round-trip) and the spawned process
    /// runs independently of cmux, so the master is torn down even as the app exits
    /// — instead of lingering for `ControlPersist` after the user closes the app or
    /// the mirror window. Best-effort: a missing/dead socket just fails fast.
    nonisolated static func spawnControlMasterExit(
        host: RemoteTmuxHost,
        sshExecutablePath: String = "/usr/bin/ssh"
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshExecutablePath)
        process.arguments = ["-O", "exit", "-o", "ControlPath=\(host.controlSocketPath)", "--", host.destination]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()  // fire-and-forget — do not wait
    }

    /// Kills each `(transport, sessionTarget)` via `tmux kill-session`. Races the kill
    /// round-trips against a single `Task.sleep(timeout)` and returns at the first to
    /// finish (`group.next()` then `cancelAll()`) — so on a RESPONSIVE connection this
    /// returns as soon as the kills land (well under `timeout`). Kills to the SAME host
    /// serialize on that host's transport actor; different hosts run in parallel.
    ///
    /// CAVEAT: `runProcess` is not cancellation-aware, so on a HUNG connection the
    /// abandoned kill child can outlive `timeout` (the structured group still awaits
    /// it). The hard bound on the user-visible app-quit is therefore the CALLER's
    /// watchdog (``AppDelegate``'s deferred-terminate reply fires regardless), not this
    /// `timeout`. The orphaned `ssh` is reaped by the OS on app exit; the kill is
    /// best-effort (it can't land on a dead connection anyway).
    nonisolated static func killSessions(
        _ jobs: [(transport: RemoteTmuxSSHTransport, target: String)],
        timeout: Duration
    ) async {
        guard !jobs.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withTaskGroup(of: Void.self) { kills in
                    for job in jobs {
                        kills.addTask { _ = try? await job.transport.runTmux(["kill-session", "-t", job.target]) }
                    }
                    await kills.waitForAll()
                }
            }
            group.addTask { try? await ContinuousClock().sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Heuristics

    /// Whether stderr indicates the remote tmux server simply isn't running.
    static func indicatesNoServer(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("no server running")
            || lowered.contains("no sessions")
            || (lowered.contains("error connecting to /") && lowered.contains("/tmux-"))
    }

    /// Whether a failed non-interactive (`BatchMode=yes`) connect failed because
    /// the host needs **interactive** authentication or host-key confirmation
    /// that batch mode cannot service — a password, an unknown/changed host key,
    /// keyboard-interactive MFA, or a FIDO touch. Used to decide whether to hand
    /// the user an interactive `ssh` (run in their terminal by `cmux ssh-tmux`) that
    /// opens the shared ControlMaster, versus surfacing a genuine
    /// unreachable/transient error.
    ///
    /// Matches the canonical OpenSSH failure phrases only. "Permission denied"
    /// already covers `Permission denied (publickey,keyboard-interactive)`, so
    /// the bare "keyboard-interactive" substring is intentionally omitted (it
    /// also appears in success-time banners). A *changed* host key ("remote host
    /// identification has changed") is included so the interactive terminal
    /// renders ssh's actionable message rather than an opaque alert — even though
    /// the user must fix `known_hosts` themselves. Algorithm-negotiation failures
    /// ("no matching host key type") are deliberately NOT matched: an interactive
    /// retry cannot fix them, so they surface as a normal error instead.
    static func indicatesAuthRequired(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("permission denied")
            || lowered.contains("host key verification failed")
            || lowered.contains("remote host identification has changed")
            || lowered.contains("authentication failed")
            || lowered.contains("too many authentication failures")
    }

    // MARK: - Process plumbing

    /// Launches a process and captures bounded stdout/stderr without blocking the actor.
    ///
    /// Each pipe is drained to EOF on a detached task so a chatty command can't
    /// deadlock against a full 64 KiB pipe buffer while we await termination.
    /// We capture only the raw fds (`Int32`, `Sendable`) across the task
    /// boundary — never the non-`Sendable` `FileHandle` — and the `Pipe`s stay
    /// alive because `process` retains them until this function returns.
    private static func runProcess(
        executable: String,
        arguments: [String]
    ) async throws -> RemoteTmuxCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let outFD = outPipe.fileHandleForReading.fileDescriptor
        let errFD = errPipe.fileHandleForReading.fileDescriptor
        let outRead = Task.detached { Self.drain(fd: outFD, maxBytes: Self.maxCapturedOutputBytes) }
        let errRead = Task.detached { Self.drain(fd: errFD, maxBytes: Self.maxCapturedOutputBytes) }
        let cancellation = RemoteTmuxProcessCancellation(
            process: process,
            stdout: outPipe.fileHandleForReading,
            stderr: errPipe.fileHandleForReading
        )

        // Install the termination handler BEFORE launching, then launch inside the
        // continuation. If `run()` and the handler assignment were separate steps, a
        // process that exits in the window between them would terminate before the
        // handler is installed — and Foundation does not invoke a terminationHandler
        // assigned after the process has already ended, so the continuation would
        // never resume and the caller would hang until its timeout. This matters for
        // the fast auth-failure exits the `cmux ssh-tmux` flow classifies.
        let exitCode: Int32
        do {
            exitCode = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { proc in
                        continuation.resume(returning: proc.terminationStatus)
                    }
                    do {
                        try process.run()
                    } catch {
                        // The process never started, so the handler will not fire; resume
                        // exactly once here with the launch failure.
                        process.terminationHandler = nil
                        continuation.resume(throwing: RemoteTmuxError.launchFailed(error.localizedDescription))
                    }
                }
            } onCancel: {
                cancellation.cancel()
            }
            try Task.checkCancellation()
        } catch {
            cancellation.cancel()
            outRead.cancel()
            errRead.cancel()
            _ = await outRead.value
            _ = await errRead.value
            throw error
        }

        let outData = await outRead.value
        let errData = await errRead.value
        return RemoteTmuxCommandResult(
            exitCode: exitCode,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Reads a file descriptor to EOF, returning at most `maxBytes`.
    ///
    /// Uses the raw `read(2)` so nothing non-`Sendable` crosses the task
    /// boundary; the owning `Pipe` keeps `fd` open for the duration.
    private static func drain(fd: Int32, maxBytes: Int) -> Data {
        var data = Data()
        var remaining = max(0, maxBytes)
        let bufferSize = 65_536
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            if Task.isCancelled { break }
            let count = buffer.withUnsafeMutableBytes { ptr -> Int in
                read(fd, ptr.baseAddress, bufferSize)
            }
            if count > 0 {
                if remaining > 0 {
                    let kept = min(count, remaining)
                    data.append(contentsOf: buffer[0..<kept])
                    remaining -= kept
                }
            } else if count == 0 {
                break // EOF
            } else if errno == EINTR {
                continue // interrupted, retry
            } else {
                break // read error; return what we have
            }
        }
        return data
    }
}
