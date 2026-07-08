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

    /// In-flight shared-master warmup, if any. ``ensureMasterReady()`` funnels every
    /// concurrent caller through this single task so the master is opened at most
    /// once even though the actor is reentrant across awaits (see that method).
    private var readinessTask: Task<Bool, Error>?

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
            throw commandFailure(result)
        }
        return RemoteTmuxSessionListParser.parse(result.stdout)
    }

    /// Probes the remote tmux client version via `tmux -V`.
    ///
    /// - Returns: the parsed version, or `nil` when `tmux -V` succeeds but its
    ///   output has no `<major>.<minor>` (a dev/distro build like `tmux master`),
    ///   which callers treat as "unknown, allow".
    /// - Throws: ``RemoteTmuxError/commandFailed`` when the command itself fails, or
    ///   ``RemoteTmuxError/tmuxNotFound(destination:)`` when `tmux` is not installed.
    func tmuxClientVersion() async throws -> RemoteTmuxVersion? {
        let result = try await run(["tmux", "-V"])
        guard result.succeeded else {
            throw commandFailure(result)
        }
        return RemoteTmuxVersion.parse(result.stdout)
    }

    /// Probes the running tmux server version via the server's `#{version}` format.
    private func tmuxServerVersionProbe() async throws -> (serverExists: Bool, version: RemoteTmuxVersion?) {
        let result = try await runTmux(["display-message", "-p", "#{version}"])
        guard result.succeeded else {
            if Self.indicatesNoServer(result.stderr) { return (serverExists: false, version: nil) }
            throw commandFailure(result)
        }
        if let version = RemoteTmuxVersion.parseServerFormat(result.stdout) {
            return (serverExists: true, version: version)
        }
        return (serverExists: true, version: nil)
    }

    /// Probes the live-subscription capability directly when server version text
    /// is unparseable. New tmux recognizes `-B` but may fail with "no current
    /// client" outside control mode; old tmux rejects the flag itself.
    private func serverSupportsRefreshClientSubscriptions() async throws -> Bool {
        let result = try await runTmux(["refresh-client", "-B", "cmux_probe::#{version}"])
        if result.succeeded { return true }
        if Self.indicatesRefreshClientSubscriptionUnsupported(result.stderr) { return false }
        if Self.indicatesRefreshClientNeedsCurrentClient(result.stderr) { return true }
        throw commandFailure(result)
    }

    /// Asserts that the remote server supports live mirroring.
    ///
    /// Call this before any `tmux -CC` control stream can launch. An unparseable
    /// running-server version falls back to a direct `refresh-client -B`
    /// capability probe so dev/distro builds are treated consistently with the
    /// cold-start path while old servers still fail before attach.
    /// When no server is running, pass `true` only for paths that will create one;
    /// those paths gate on the tmux client binary that will become the new server.
    func assertMinimumTmuxVersion(checkClientWhenNoServer: Bool) async throws {
        let serverProbe = try await tmuxServerVersionProbe()
        if serverProbe.serverExists {
            guard let version = serverProbe.version else {
                if try await serverSupportsRefreshClientSubscriptions() {
                    return
                }
                throw RemoteTmuxError.unsupportedTmux(detected: RemoteTmuxError.unknownVersionDisplayName)
            }
            try Self.assertSupportedTmuxVersion(version)
            return
        }
        guard checkClientWhenNoServer else { return }
        if let version = try await tmuxClientVersion() {
            try Self.assertSupportedTmuxVersion(version)
        }
    }

    private static func assertSupportedTmuxVersion(_ version: RemoteTmuxVersion) throws {
        if !version.meetsMinimum {
            throw RemoteTmuxError.unsupportedTmux(detected: version.displayString)
        }
    }

    /// Asserts that the remote server supports live mirroring, then discovers sessions.
    func discoverMirrorSessions(createIfEmpty: Bool) async throws -> [RemoteTmuxSession] {
        try await assertMinimumTmuxVersion(checkClientWhenNoServer: createIfEmpty)
        var sessions = try await listSessions()
        if sessions.isEmpty, createIfEmpty {
            _ = try? await runTmux(["new-session", "-d"])
            sessions = try await listSessions()
        }
        return sessions
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
    /// A leading literal `tmux` is the `runTmux(_:)` contract and selects the
    /// remote tmux resolver; other commands are treated as explicit remote argv.
    @discardableResult
    func run(_ remoteArgs: [String]) async throws -> RemoteTmuxCommandResult {
        try host.ensureControlSocketDirectory()
        let remoteCommand: String
        if remoteArgs.first == "tmux" {
            remoteCommand = RemoteTmuxHost.tmuxRemoteCommand(arguments: Array(remoteArgs.dropFirst()))
        } else {
            remoteCommand = remoteArgs
                .map { RemoteTmuxHost.shellSingleQuoted($0) }
                .joined(separator: " ")
        }
        // `--` ends ssh option parsing so a destination beginning with `-`
        // (e.g. `-oProxyCommand=…`) can never be consumed as an ssh option.
        let sshArgs =
            host.sshControlArguments(controlPersistSeconds: controlPersistSeconds, batchMode: true)
            + ["--", host.destination, remoteCommand]
        return try await Self.runProcess(executable: sshExecutablePath, arguments: sshArgs)
    }

    /// Opens the shared SSH ControlMaster (if it isn't already up) and confirms it
    /// accepts multiplexed sessions, so the burst of `tmux -CC attach` connections
    /// the controller fires next — each `ControlMaster=auto`
    /// (``RemoteTmuxHost/controlModeArguments``) — rides a *ready* master instead of
    /// all racing to create one at the same `ControlPath`.
    ///
    /// On a cold first attach with many sessions, that creation race makes
    /// all-but-one connection fail with "ControlSocket … already exists, disabling
    /// multiplexing", so only one or two sessions mirror (#6732). Even discovery
    /// (which opens the master implicitly) leaves a brief background hand-off window
    /// where the socket exists but isn't yet accepting sessions; `ssh -O check` is
    /// the authoritative "ready now" signal that closes it.
    ///
    /// Idempotent: returns `true` at once when a master is already live (warm path);
    /// otherwise opens it exactly once with `run(["true"])` — a single connection
    /// can't lose the creation race — and then confirms with one authoritative
    /// `ssh -O check` (a non-multiplexed fallback can make `run` succeed without a
    /// live master, so the open's exit code is not trusted). A single mux-socket
    /// query, never a timer or poll. Returns `false` only when readiness can't be
    /// confirmed; the controller fails closed on `false` (aborts the burst rather
    /// than racing the cold master).
    ///
    /// Single-flight: the actor is reentrant across `await`, so two concurrent
    /// bulk-mirror callers for the same host (e.g. a dedicated-window attach and a
    /// `remote.tmux.mirror` socket call) could otherwise both observe no master and
    /// both open it, recreating the race. Every caller shares one in-flight
    /// ``readinessTask``; the check-create-store below is a single synchronous actor
    /// step (no `await` between them), so only one caller becomes the creator.
    ///
    /// Not cancellation-aware by itself: the shared warmup is unstructured and
    /// bounded by `ConnectTimeout`, so a cancelled caller awaits its completion
    /// rather than tearing it down for the others. Callers that must bail re-check
    /// `Task.checkCancellation()` after this — as the controller does before
    /// creating the dedicated window.
    @discardableResult
    func ensureMasterReady() async throws -> Bool {
        if let existing = readinessTask {
            return try await existing.value
        }
        let task = Task { try await self.performMasterReady() }
        readinessTask = task
        defer { readinessTask = nil }
        return try await task.value
    }

    /// The actual warmup, run exactly once per ``readinessTask`` (see
    /// ``ensureMasterReady()`` for the single-flight + readiness rationale).
    private func performMasterReady() async throws -> Bool {
        try? host.ensureControlSocketDirectory()
        if try await masterIsRunning() { return true }
        // Warm the shared master once, then confirm. The open's exit code is not
        // trusted (a non-multiplexed fallback can make `run` exit 0 with no live
        // master — see the doc comment); the post-open `ssh -O check` is authoritative.
        _ = try? await run(["true"])
        return try await masterIsRunning()
    }

    /// Whether the shared ControlMaster is live and accepting sessions, via the
    /// local `ssh -O check` control command. `-O check` hits the LOCAL control
    /// socket only (identified by `ControlPath`), so it never opens a network
    /// connection and returns in milliseconds.
    ///
    /// Propagates `CancellationError` (so a cancelled ``ensureMasterReady()`` aborts
    /// rather than mis-reading the cancellation as "no master"); collapses only
    /// ordinary launch/socket failures to `false`.
    private func masterIsRunning() async throws -> Bool {
        do {
            let result = try await Self.runProcess(
                executable: sshExecutablePath,
                arguments: ["-O", "check", "-o", "ControlPath=\(host.controlSocketPath)", "--", host.destination]
            )
            return result.succeeded
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }
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

    static func indicatesRefreshClientSubscriptionUnsupported(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        let tokens = lowered.split { character in
            !(character.isLetter || character.isNumber || character == "-")
        }.map(String.init)
        let mentionsBFlag = tokens.enumerated().contains { index, token in
            if token == "-b" || token == "--b" { return true }
            guard token == "b" else { return false }
            if index > 0, tokens[index - 1] == "flag" || tokens[index - 1] == "option" {
                return true
            }
            if index > 1, tokens[index - 1] == "--" {
                let optionNoun = tokens[index - 2]
                return optionNoun == "flag" || optionNoun == "option"
            }
            return false
        }
        let rejectsOption = lowered.contains("unknown flag")
            || lowered.contains("unknown option")
            || lowered.contains("invalid option")
            || lowered.contains("illegal option")
        return mentionsBFlag && rejectsOption
    }

    static func indicatesRefreshClientNeedsCurrentClient(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("no current client")
            || lowered.contains("not a client")
            || lowered.contains("not a control client")
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
