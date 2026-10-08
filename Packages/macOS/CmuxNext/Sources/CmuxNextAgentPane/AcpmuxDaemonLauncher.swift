import Darwin
import Foundation
import os
import Synchronization

/// Starts a detached acpmux daemon and returns its WebSocket endpoint from
/// the `--ready-fd` line, so a fresh daemon needs no status round trip.
///
/// The daemon runs as a background job of a throwaway `/bin/sh` with job
/// control on (`set -m`), so it gets its own process group, is adopted by
/// launchd when the shell exits, and outlives the app (its sessions are
/// durable state). The launcher reaps the shell. Its fd 3 is our pipe; stdout and stderr go to
/// `<home>/daemon.log`.
nonisolated enum AcpmuxDaemonLauncher {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.acpmux")
    nonisolated enum Failure: Error, Equatable {
        case spawnFailed(String)
        /// The daemon exited before it was ready; its log says why.
        case exited(logPath: String)
        /// Ready, but without a WebSocket listener (the port was taken).
        case noWebSocket(logPath: String)
    }

    static let script = #"set -m; "$@" 3>&1 1>>"$ACPMUX_LAUNCH_LOG" 2>&1 </dev/null &"#

    static func arguments(for environment: AcpmuxEnvironment) -> [String] {
        ["-c", script, "acpmux-launch", environment.executable.path, "daemon", "run", "--ready-fd", "3"]
            + environment.daemonArguments
    }

    /// The daemon's environment: this app's, without any inherited Computer
    /// Use variable, plus `childEnvironment`, the current Computer Use socket
    /// and agent token (never the host token), and the launch knobs.
    static func spawnEnvironment(_ environment: AcpmuxEnvironment, inherited: [String: String]) -> [String: String] {
        let computerUse = Set(AcpmuxEnvironment.computerUseKeys + [AcpmuxEnvironment.computerUseHostKey])
        var variables = inherited.filter { !computerUse.contains($0.key) }.merging(environment.childEnvironment) { $1 }
        for key in AcpmuxEnvironment.computerUseKeys {
            if let value = environment.computerUse[key], !value.isEmpty { variables[key] = value }
        }
        variables["ACPMUX_LAUNCH_LOG"] = environment.logPath
        variables["ACPMUX_LOGIN_ENV"] = "1"
        return variables
    }

    @concurrent static func launch(_ environment: AcpmuxEnvironment, deadline: Duration = .seconds(20)) async throws -> AcpmuxWebEndpoint {
        try await launch(environment, deadline: deadline, onSpawn: { _ in })
    }

    /// `onSpawn` gets the launch shell's pid (tests check that it was reaped).
    @concurrent static func launch(_ environment: AcpmuxEnvironment, deadline: Duration,
                                   onSpawn: @Sendable (pid_t) -> Void) async throws -> AcpmuxWebEndpoint {
        logger.info("acpmux launch requested executable=\(environment.executable.path, privacy: .public) home=\(environment.home.path, privacy: .public) socket=\(environment.socketPath, privacy: .public) args=\(environment.daemonArguments.joined(separator: " "), privacy: .public)")
        try FileManager.default.createDirectory(at: environment.home, withIntermediateDirectories: true)
        let variables = spawnEnvironment(environment, inherited: ProcessInfo.processInfo.environment)
        logger.info("acpmux launch environment home=\(variables["ACPMUX_HOME", default: ""], privacy: .public) socket=\(variables["ACPMUX_SOCKET", default: ""], privacy: .public) pathPresent=\(variables["PATH"] != nil, privacy: .public)")
        var outputPipe: [Int32] = [-1, -1]
        guard Darwin.pipe(&outputPipe) == 0 else {
            throw Failure.spawnFailed(String(cString: strerror(errno)))
        }
        defer {
            if outputPipe[0] >= 0 { Darwin.close(outputPipe[0]) }
            if outputPipe[1] >= 0 { Darwin.close(outputPipe[1]) }
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            throw Failure.spawnFailed("unable to initialize acpmux spawn")
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        let actionStatus = posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO)
        guard actionStatus == 0,
              posix_spawn_file_actions_addclose(&actions, outputPipe[0]) == 0,
              "/dev/null".withCString({ path in
                  posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, path, O_RDONLY, 0)
              }) == 0,
              "/dev/null".withCString({ path in
                  posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, path, O_WRONLY, 0)
              }) == 0 else {
            throw Failure.spawnFailed("unable to configure acpmux spawn")
        }
        let spawnFlags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID)
        guard posix_spawnattr_setflags(&attributes, spawnFlags) == 0 else {
            throw Failure.spawnFailed("unable to configure acpmux descriptor policy")
        }

        var processIdentifier: pid_t = 0
        // posix_spawn follows exec(2)'s argv contract. Foundation.Process accepts
        // arguments without argv[0], but the shell requires its executable name
        // in argv[0] before `-c` and the script.
        let spawnArguments = ["/bin/sh"] + arguments(for: environment)
        let spawnStatus = try Self.withCStringArray(spawnArguments) { argv in
            try Self.withCStringArray(variables.map { "\($0.key)=\($0.value)" }) { envp in
                "/bin/sh".withCString { executable in
                    posix_spawn(&processIdentifier, executable, &actions, &attributes, argv, envp)
                }
            }
        }
        guard spawnStatus == 0 else {
            logger.error("acpmux spawn failed status=\(spawnStatus, privacy: .public) errno=\(String(cString: strerror(spawnStatus)), privacy: .public) executable=/bin/sh")
            throw Failure.spawnFailed(String(cString: strerror(spawnStatus)))
        }
        logger.info("acpmux spawn succeeded executable=/bin/sh")
        onSpawn(processIdentifier)
        // The shell exits as soon as it has put the daemon in the background (the daemon
        // goes to launchd). Reap it on every path out, or each launch leaves a zombie child
        // in this process (cx-xqng).
        let ready: Result<AcpmuxWebEndpoint, any Error>
        do {
            ready = .success(try await readReadyLine(&outputPipe, environment: environment, deadline: deadline))
        } catch {
            ready = .failure(error)
        }
        await Self.reap(processIdentifier)
        return try ready.get()
    }

    private static func readReadyLine(_ outputPipe: inout [Int32], environment: AcpmuxEnvironment,
                                      deadline: Duration) async throws -> AcpmuxWebEndpoint {
        // Only the spawned shell and daemon may hold the write end. The CLOEXEC
        // default above closes every inherited descriptor; the shell creates
        // descriptor 3 explicitly for the ready line.
        Darwin.close(outputPipe[1])
        outputPipe[1] = -1
        let reader = AgentPaneLineReader(handle: FileHandle(fileDescriptor: outputPipe[0], closeOnDealloc: false))
        let line: String
        do {
            line = try await withAgentPaneDeadline(deadline, label: "acpmux start") { try await reader.firstLine() }
        } catch AgentPaneLineReader.Failure.endOfFile {
            throw Failure.exited(logPath: environment.logPath)
        }
        guard let ready = AcpmuxReadyLine.parse(line) else { throw Failure.exited(logPath: environment.logPath) }
        guard let webURL = ready.webUrl, let endpoint = AcpmuxWebEndpoint(webURL: webURL) else {
            throw Failure.noWebSocket(logPath: environment.logPath)
        }
        return endpoint
    }

    /// Collects the launch shell's exit status without blocking a thread while it runs.
    /// The shell exits as soon as it has put the daemon in the background, so the wait
    /// has no bound: a shell left unreaped stays a zombie child of this process for its
    /// whole life (cx-xqng). The earlier version leaked it two ways: a non-blocking
    /// `waitpid` right after the exit event, which the kernel can post before the
    /// status is collectable, and a 5 s bound a busy machine can pass (hosted runs
    /// 37835676794, 37845131094, 37847351675: three launches, three zombies).
    ///
    /// The exit source is armed before the second `waitpid`, so an exit that comes
    /// between the first check and the arming is still seen: the shell is then a
    /// zombie and the check after arming reaps it. A shell that never exited would
    /// hold the launch; the script only backgrounds the daemon, in its own session
    /// (no terminal can stop it), so it cannot.
    private static func reap(_ pid: pid_t) async {
        if collect(pid) { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "cmux.next.agent-pane.acpmux-launch-reap.\(pid)")
            nonisolated(unsafe) let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            let done = Mutex(false)
            let finish: @Sendable () -> Void = {
                guard done.withLock({ done in defer { done = true }; return !done }) else { return }
                source.cancel()
                continuation.resume()
            }
            source.setEventHandler {
                // The exit event can come before the kernel makes the exit status
                // collectable; this blocking wait then ends as soon as it is.
                collectExited(pid)
                finish()
            }
            source.resume()
            queue.async { if collect(pid) { finish() } }
        }
    }

    /// One non-blocking `waitpid`: true once the shell is reaped (or is no child of ours).
    private static func collect(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { return true }
        guard result == -1 else { return false }
        let failure = errno
        if failure == EINTR { return false }
        if failure != ECHILD { logger.error("acpmux launch shell reap failed errno=\(failure, privacy: .public)") }
        return true
    }

    /// A blocking `waitpid` for a shell whose exit event came: it returns at once.
    private static func collectExited(_ pid: pid_t) {
        var status: Int32 = 0
        // concurrency-allow: on the reap queue after the shell's exit event; the status is collectable at once
        while waitpid(pid, &status, 0) == -1 {
            let failure = errno
            if failure == EINTR { continue }
            if failure != ECHILD { logger.error("acpmux launch shell reap failed errno=\(failure, privacy: .public)") }
            return
        }
    }

    private static func withCStringArray<Value>(
        _ strings: [String],
        operation: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Value
    ) throws -> Value {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        guard pointers.allSatisfy({ $0 != nil }) else {
            pointers.forEach { free($0) }
            throw Failure.spawnFailed("unable to allocate acpmux spawn arguments")
        }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw Failure.spawnFailed("unable to allocate acpmux spawn arguments")
            }
            return try operation(baseAddress)
        }
    }
}
