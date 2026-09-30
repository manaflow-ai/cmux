import Darwin
import Foundation
import os

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
        // Current acpmux reports readiness on --ready-fd; older builds reject the flag and
        // exit, which shows up as EOF on the pipe, and then start again with log watching.
        if let connection = try await launchWithReadyFD(executable: executable, environment: environment, logPath: logPath, connect: connect) {
            log.info("daemon ready via --ready-fd")
            return connection
        }
        log.info("daemon without --ready-fd support: falling back to log-watch readiness")
        try spawnDetached(
            executable: executable,
            arguments: ["daemon", "run"] + environment.daemonArguments,
            environment: environment.childEnvironment(base: baseEnvironment),
            logPath: logPath,
            readyWriteFD: nil
        )
        let signals = Self.logChanges(logPath: logPath)
        let timeout = readinessTimeout
        return try await withThrowingTaskGroup(of: Connection?.self) { group in
            group.addTask {
                if let connection = connect() { return connection }
                for await _ in signals {
                    if let connection = connect() { return connection }
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

    private var log: Logger { Logger(subsystem: "com.cmuxterm.acpmux", category: "daemon-launch") }

    /// Starts the daemon with `--ready-fd 3` and waits for its ready line.
    /// - Returns: A connection, or `nil` when the pipe closed without a ready line (a daemon
    ///   that predates the flag).
    private func launchWithReadyFD<Connection: Sendable>(
        executable: String,
        environment: AcpmuxDaemonEnvironment,
        logPath: String,
        connect: @escaping @Sendable () -> Connection?
    ) async throws -> Connection? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        let readFD = fds[0], writeFD = fds[1]
        do {
            try spawnDetached(
                executable: executable,
                arguments: ["daemon", "run", "--ready-fd", "3"] + environment.daemonArguments,
                environment: environment.childEnvironment(base: baseEnvironment),
                logPath: logPath,
                readyWriteFD: writeFD
            )
        } catch {
            close(readFD)
            close(writeFD)
            throw error
        }
        close(writeFD)
        let timeout = readinessTimeout
        // A blocking read of the pipe on a detached task keyed by the raw fd; the deadline
        // task closes nothing, so the read ends at EOF or the ready line.
        let readyLine: String? = try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                await Task.detached { Self.readLine(fd: readFD) }.value
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AcpmuxDaemonError.timedOut(logPath: logPath)
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        close(readFD)
        guard let readyLine, readyLine.contains("\"ready\""), readyLine.contains("true") else { return nil }
        return connect()
    }

    private static func readLine(fd: Int32) -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = read(fd, &byte, 1)
            if count == 1 {
                if byte == 0x0A { break }
                bytes.append(byte)
            } else if count == 0 || errno != EINTR {
                break
            }
        }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }

    /// Daemon log writes as a stream. A vnode `DispatchSource` is the only event API for
    /// file changes; it only forwards into the stream.
    private static func logChanges(logPath: String) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let fd = open(logPath, O_EVTONLY)
            guard fd >= 0 else {
                continuation.finish()
                return
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .delete],
                queue: DispatchQueue(label: "com.cmuxterm.acpmux.daemon-readiness")
            )
            source.setEventHandler { continuation.yield() }
            source.setCancelHandler { close(fd) }
            source.resume()
            continuation.onTermination = { _ in source.cancel() }
        }
    }

    /// Starts the daemon as an orphan owned by launchd.
    ///
    /// `/bin/sh` starts the daemon in the background and exits at once; the launcher reaps
    /// the shell, and launchd adopts and later reaps the daemon. cmux therefore never holds
    /// a child that can become a zombie, and the daemon outlives cmux. `setsid` puts both
    /// in a new session, away from the app's process group.
    private func spawnDetached(
        executable: String,
        arguments: [String],
        environment: [String: String],
        logPath: String,
        readyWriteFD: Int32?
    ) throws {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, logPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        posix_spawn_file_actions_adddup2(&fileActions, 1, 2)
        if let readyWriteFD {
            // The daemon writes its ready line to descriptor 3.
            posix_spawn_file_actions_adddup2(&fileActions, readyWriteFD, 3)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        // `"$@" &` runs the daemon with the shell's descriptors; the shell then exits.
        let shellArguments = ["/bin/sh", "-c", "\"$@\" &", "acpmux-launch", executable] + arguments
        let argv = shellArguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var shellPID: pid_t = 0
        let result = posix_spawn(&shellPID, "/bin/sh", &fileActions, &attributes, argv, envp)
        guard result == 0 else { throw AcpmuxDaemonError.spawnFailed(result) }
        var status: Int32 = 0
        while waitpid(shellPID, &status, 0) < 0, errno == EINTR {}
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
