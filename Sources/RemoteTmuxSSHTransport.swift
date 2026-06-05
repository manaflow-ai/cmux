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
    /// The host this transport talks to.
    let host: RemoteTmuxHost

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

    /// Tears down the shared SSH master (e.g. when the user removes a host).
    func shutdownMaster() async {
        _ = try? await Self.runProcess(
            executable: sshExecutablePath,
            arguments: ["-O", "exit", "-o", "ControlPath=\(host.controlSocketPath)", "--", host.destination]
        )
    }

    // MARK: - Heuristics

    /// Whether stderr indicates the remote tmux server simply isn't running.
    static func indicatesNoServer(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("no server running")
            || lowered.contains("no sessions")
            || lowered.contains("error connecting to")
    }

    // MARK: - Process plumbing

    /// Launches a process and captures stdout/stderr without blocking the actor.
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
        let outRead = Task.detached { Self.drain(fd: outFD) }
        let errRead = Task.detached { Self.drain(fd: errFD) }

        do {
            try process.run()
        } catch {
            outRead.cancel()
            errRead.cancel()
            throw RemoteTmuxError.launchFailed(error.localizedDescription)
        }

        let exitCode: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }
        }

        let outData = await outRead.value
        let errData = await errRead.value
        return RemoteTmuxCommandResult(
            exitCode: exitCode,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Reads a file descriptor to EOF, returning everything read.
    ///
    /// Uses the raw `read(2)` so nothing non-`Sendable` crosses the task
    /// boundary; the owning `Pipe` keeps `fd` open for the duration.
    private static func drain(fd: Int32) -> Data {
        var data = Data()
        let bufferSize = 65_536
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let count = buffer.withUnsafeMutableBytes { ptr -> Int in
                read(fd, ptr.baseAddress, bufferSize)
            }
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
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
