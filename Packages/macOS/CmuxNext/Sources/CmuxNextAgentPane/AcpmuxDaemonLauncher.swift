import Darwin
import Foundation
import os

/// Starts a detached acpmux daemon and returns its WebSocket endpoint from
/// the `--ready-fd` line, so a fresh daemon needs no status round trip.
///
/// The daemon runs as a background job of a throwaway `/bin/sh` with job
/// control on (`set -m`), so it gets its own process group, is adopted by
/// launchd when the shell exits, and outlives the app (its sessions are
/// durable state). Its fd 3 is our pipe; stdout and stderr go to
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

    @concurrent static func launch(_ environment: AcpmuxEnvironment, deadline: Duration = .seconds(20)) async throws -> AcpmuxWebEndpoint {
        logger.info("acpmux launch requested executable=\(environment.executable.path, privacy: .public) home=\(environment.home.path, privacy: .public) socket=\(environment.socketPath, privacy: .public) args=\(environment.daemonArguments.joined(separator: " "), privacy: .public)")
        try FileManager.default.createDirectory(at: environment.home, withIntermediateDirectories: true)
        var variables = ProcessInfo.processInfo.environment.merging(environment.childEnvironment) { $1 }
        variables["ACPMUX_LAUNCH_LOG"] = environment.logPath
        variables["ACPMUX_LOGIN_ENV"] = "1"
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
