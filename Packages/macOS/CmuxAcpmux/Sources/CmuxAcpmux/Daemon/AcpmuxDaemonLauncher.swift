import Darwin
import Foundation

/// Starts a detached `acpmux daemon run` and waits until its socket accepts connections.
///
/// The daemon writes `listening on <path>` to its log once the socket is bound, so the
/// launcher watches the log file and the child process instead of polling. A deadline
/// bounds the wait.
public struct AcpmuxDaemonLauncher: Sendable {
    /// Maximum time to wait for the socket after spawning.
    public var readinessTimeout: Duration
    private let userHome: URL
    private let baseEnvironment: [String: String]

    /// Creates a launcher.
    /// - Parameters:
    ///   - userHome: The user's home directory, for the default daemon home.
    ///   - baseEnvironment: The environment the daemon inherits.
    ///   - readinessTimeout: Wait bound. A cold daemon imports the login shell environment before it binds its socket, which took about a minute with a heavy zsh profile.
    public init(userHome: URL, baseEnvironment: [String: String], readinessTimeout: Duration = .seconds(90)) {
        self.userHome = userHome
        self.baseEnvironment = baseEnvironment
        self.readinessTimeout = readinessTimeout
    }

    /// Spawns the daemon and returns once `connect` succeeds.
    /// - Parameters:
    ///   - environment: The daemon environment.
    ///   - connect: Attempts one connection; returns `nil` when the socket does not answer yet.
    /// - Throws: ``AcpmuxDaemonError`` when no executable exists, the spawn fails, the daemon
    ///   exits, or the deadline passes.
    public func launch<Connection: Sendable>(
        _ environment: AcpmuxDaemonEnvironment,
        connect: @escaping @Sendable () -> Connection?
    ) async throws -> Connection {
        let fileManager = FileManager.default
        guard let executable = environment.executableCandidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
            throw AcpmuxDaemonError.executableNotFound
        }
        let logPath = environment.logPath(userHome: userHome)
        try fileManager.createDirectory(
            atPath: (logPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: logPath) {
            fileManager.createFile(atPath: logPath, contents: nil)
        }
        let pid = try spawn(
            executable: executable,
            arguments: ["daemon", "run"] + environment.daemonArguments,
            environment: environment.childEnvironment(base: baseEnvironment),
            logPath: logPath
        )
        let signals = Self.readinessSignals(logPath: logPath, pid: pid)
        let timeout = readinessTimeout
        return try await withThrowingTaskGroup(of: Connection?.self) { group in
            group.addTask {
                if let connection = connect() { return connection }
                for await signal in signals {
                    if let connection = connect() { return connection }
                    if signal == .processExited { throw AcpmuxDaemonError.daemonExited(logPath: logPath) }
                }
                throw AcpmuxDaemonError.daemonExited(logPath: logPath)
            }
            group.addTask {
                // A genuine deadline, not a poll: readiness is event-driven above.
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let connection = first else {
                throw AcpmuxDaemonError.timedOut(logPath: logPath)
            }
            return connection
        }
    }

    private enum ReadinessSignal: Sendable { case logChanged, processExited }

    /// Log writes and child exit as one stream. Dispatch sources are the only event API
    /// for vnode and process events; they only forward into the stream.
    private static func readinessSignals(logPath: String, pid: pid_t) -> AsyncStream<ReadinessSignal> {
        AsyncStream { continuation in
            let fd = open(logPath, O_EVTONLY)
            let queue = DispatchQueue(label: "com.cmuxterm.acpmux.daemon-readiness")
            var fileSource: (any DispatchSourceFileSystemObject)?
            if fd >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd,
                    eventMask: [.write, .extend],
                    queue: queue
                )
                source.setEventHandler { continuation.yield(.logChanged) }
                source.setCancelHandler { close(fd) }
                source.resume()
                fileSource = source
            }
            let processSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            processSource.setEventHandler {
                var status: Int32 = 0
                waitpid(pid, &status, WNOHANG)
                continuation.yield(.processExited)
                continuation.finish()
            }
            processSource.resume()
            let ownedFileSource = fileSource
            continuation.onTermination = { _ in
                ownedFileSource?.cancel()
                processSource.cancel()
            }
        }
    }

    private func spawn(executable: String, arguments: [String], environment: [String: String], logPath: String) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, logPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        posix_spawn_file_actions_adddup2(&fileActions, 1, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // New session so the daemon outlives cmux and ignores the app's process group signals.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &fileActions, &attributes, argv, envp)
        guard result == 0 else { throw AcpmuxDaemonError.spawnFailed(result) }
        return pid
    }
}

/// Errors from starting the acpmux daemon.
public enum AcpmuxDaemonError: Error, Sendable, Equatable {
    /// No `acpmux` executable was found in the bundle or on `PATH`.
    case executableNotFound
    /// `posix_spawn` failed with the given errno.
    case spawnFailed(Int32)
    /// The daemon exited before its socket answered. See the log.
    case daemonExited(logPath: String)
    /// The socket did not answer before the deadline. See the log.
    case timedOut(logPath: String)
}
