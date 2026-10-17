import Darwin
import Foundation

/// One agent CLI child process that speaks JSON Lines over stdio.
///
/// The child is spawned in its own process group, so ``terminate()`` reaches
/// the tools it started too. stdout is read by the pipe's readability handler
/// (no polling) and framed into ``lines``, in order, which ends when every
/// holder of stdout closed it. stderr keeps a short tail for error messages.
///
/// Writes go to a private serial queue: a prompt line of several MB never
/// blocks the caller (an actor on the cooperative pool), and a child that is
/// not reading stdin cannot deadlock the driver. Writes never raise
/// `SIGPIPE`: a write to a dead process fails (`EPIPE`) and reports false.
///
/// The object keeps itself alive until the child exited and stdout ended,
/// so a terminated process is always reaped and, after
/// ``terminationGrace``, killed.
final class ChiefLineProcess: @unchecked Sendable {
    /// stdout, one element per line, finished at end of stream.
    let lines: AsyncStream<Data>
    /// The child's pid, also its process group id.
    let pid: pid_t
    /// How long ``terminate()`` waits after `SIGTERM` before `SIGKILL`.
    let terminationGrace: DispatchTimeInterval

    private let stdinFD: Int32
    private let output: FileHandle
    private let errors: FileHandle
    private let lock = NSLock()
    /// Serial: every stdin write, then the close of stdin.
    private let writer = DispatchQueue(label: "com.cmuxterm.chief.line-process.stdin")
    /// Serial: reaping, signals and the kill timer.
    private let reaper = DispatchQueue(label: "com.cmuxterm.chief.line-process.exit")
    private var framer = ChiefLineFramer()
    private var stderrTail = Data()
    private var closed = false
    private var stdinClosed = false
    private var exited = false
    private var stdoutEnded = false
    // Touched on `reaper` only (and in init before the source runs).
    private var exitSource: (any DispatchSourceProcess)?
    private var killTimer: (any DispatchSourceTimer)?
    private static let stderrLimit = 4096

    /// Launches the process.
    ///
    /// - Parameters:
    ///   - executable: The program to run.
    ///   - arguments: Its arguments.
    ///   - environment: Its complete environment.
    ///   - workingDirectory: Its working directory.
    ///   - terminationGrace: How long ``terminate()`` waits before `SIGKILL`.
    /// - Throws: When the program cannot be launched.
    init(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL,
         terminationGrace: DispatchTimeInterval = .seconds(3)) throws {
        self.terminationGrace = terminationGrace
        var stdinPipe: [Int32] = [-1, -1]
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        func closeAll() {
            for fd in stdinPipe + stdoutPipe + stderrPipe where fd >= 0 { Darwin.close(fd) }
        }
        guard pipe(&stdinPipe) == 0, pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            let code = errno
            closeAll()
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        // Other spawns in the app must not inherit these ends.
        for fd in stdinPipe + stdoutPipe + stderrPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Own process group (pgid = pid), default signal handling, empty
        // mask, and no inherited descriptors beyond stdio.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGCHLD, SIGALRM, SIGUSR1, SIGUSR2] {
            sigaddset(&defaults, signal)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        var child: pid_t = 0
        let status = posix_spawn(&child, executable.path, &actions, &attributes, argv, envp)
        guard status == 0 else {
            closeAll()
            throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
        }
        Darwin.close(stdinPipe[0])
        Darwin.close(stdoutPipe[1])
        Darwin.close(stderrPipe[1])
        pid = child
        stdinFD = stdinPipe[1]
        _ = fcntl(stdinFD, F_SETNOSIGPIPE, 1)
        output = FileHandle(fileDescriptor: stdoutPipe[0], closeOnDealloc: true)
        errors = FileHandle(fileDescriptor: stderrPipe[0], closeOnDealloc: true)

        let (stream, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        lines = stream
        // Strong captures: the handlers keep the object alive until their stream ends.
        output.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                if let tail = withLock({ framer.finish() }) { continuation.yield(tail) }
                continuation.finish()
                withLock { stdoutEnded = true }
                reaper.async { [self] in finishIfDone() }
                return
            }
            for line in withLock({ framer.append(data) }) { continuation.yield(line) }
        }
        errors.readabilityHandler = { [self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            withLock {
                stderrTail.append(data)
                if stderrTail.count > Self.stderrLimit { stderrTail = stderrTail.suffix(Self.stderrLimit) }
            }
        }
        let source = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: reaper)
        source.setEventHandler { [self] in reap() }
        exitSource = source
        source.resume()
        // An exit before the source was armed is reaped here.
        reaper.async { [self] in reap() }
    }

    deinit {
        if !stdinClosed { Darwin.close(stdinFD) }
    }

    /// Queues one line for stdin; returns at once.
    ///
    /// - Parameters:
    ///   - line: Bytes ending in a newline.
    ///   - completion: Called on the write queue once the line was written
    ///     (true) or failed, for example with `EPIPE` (false). Not called
    ///     when the line is refused.
    /// - Returns: False when stdin is already closed (the line is refused).
    @discardableResult
    func write(_ line: Data, completion: (@Sendable (Bool) -> Void)? = nil) -> Bool {
        guard !withLock({ closed }) else { return false }
        writer.async { [self] in
            let written = !withLock({ stdinClosed }) && Self.writeAll(stdinFD, line)
            completion?(written)
        }
        return true
    }

    /// The last few KB the process wrote to stderr, trimmed.
    var stderrText: String {
        let tail = withLock { stderrTail }
        return String(decoding: tail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the child has not been reaped yet.
    var isRunning: Bool { !withLock { exited } }

    /// Closes stdin and stops the process group: `SIGTERM` now, `SIGKILL`
    /// once ``terminationGrace`` elapses with the child or a holder of its
    /// stdout still alive. Safe to call more than once.
    func terminate() {
        let first: Bool = withLock {
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        // After queued writes; a write blocked on a full pipe ends with EPIPE once the child dies.
        writer.async { [self] in
            withLock { stdinClosed = true }
            Darwin.close(stdinFD)
        }
        reaper.async { [self] in
            guard !isDone else { return }
            signalGroup(SIGTERM)
            // A bounded, intentional delay: the grace period before SIGKILL.
            let timer = DispatchSource.makeTimerSource(queue: reaper)
            timer.schedule(deadline: .now() + terminationGrace)
            timer.setEventHandler { [self] in
                killTimer?.cancel()
                killTimer = nil
                if !isDone { signalGroup(SIGKILL) }
            }
            killTimer = timer
            timer.resume()
        }
    }

    /// Whether the child was reaped and stdout ended (nothing left to stop).
    private var isDone: Bool { withLock { exited && stdoutEnded } }

    /// Sends `signal` to the child and its process group. Runs on `reaper`,
    /// which also reaps, so the pid is never signalled after it was reaped
    /// unless the group still holds stdout (the group id is then in use).
    private func signalGroup(_ signal: Int32) {
        if !withLock({ exited }) { Darwin.kill(pid, signal) }
        Darwin.killpg(pid, signal)
    }

    private func reap() {
        guard !withLock({ exited }) else { return }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        // 0: still running. ECHILD: someone else reaped it.
        guard result == pid || (result < 0 && errno == ECHILD) else { return }
        withLock { exited = true }
        exitSource?.cancel()
        exitSource = nil
        finishIfDone()
    }

    private func finishIfDone() {
        guard isDone else { return }
        killTimer?.cancel()
        killTimer = nil
    }

    /// Writes all of `data`, retrying short writes and `EINTR`.
    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var cursor = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(fd, cursor, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                cursor += written
                remaining -= written
            }
            return true
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Finds an agent CLI and builds its environment.
///
/// The CLI is looked up on the `PATH` of the turn's environment (the app's
/// own `PATH` otherwise), so the user's install wins, unless an explicit
/// override path is configured.
enum ChiefExecutableResolver {
    /// The process environment for a CLI: the app's environment, then the
    /// turn's, then `overrides`.
    ///
    /// - Parameters:
    ///   - request: The turn's extra environment.
    ///   - overrides: Values that always win (hook opt-outs).
    /// - Returns: The complete environment.
    static func environment(_ request: [String: String], overrides: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // The app is not a terminal; a Chief must not claim one.
        for key in ["CMUX_SURFACE_ID", "CMUX_PANEL_ID", "CMUX_WORKSPACE_ID", "CMUX_TAB_ID"] {
            environment.removeValue(forKey: key)
        }
        environment.merge(request) { _, new in new }
        environment.merge(overrides) { _, new in new }
        return environment
    }

    /// Resolves `name` to an executable file.
    ///
    /// - Parameters:
    ///   - name: The program name, such as `claude`.
    ///   - override: An explicit path that wins when it is executable.
    ///   - environment: The environment whose `PATH` is searched.
    /// - Returns: The executable, nil when none is found.
    static func resolve(_ name: String, override: URL?, environment: [String: String]) -> URL? {
        let files = FileManager.default
        if let override, files.isExecutableFile(atPath: override.path) { return override }
        let path = environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        var directories = path.split(separator: ":").map(String.init)
        // A GUI app's PATH is minimal; also try the usual install places.
        let home = files.homeDirectoryForCurrentUser.path
        directories += ChiefSearchPath(home: home).fallbackDirectories
        for directory in directories where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name)
            if files.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
