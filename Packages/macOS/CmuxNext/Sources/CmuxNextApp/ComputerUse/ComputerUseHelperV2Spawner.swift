// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Synchronization

/// A started helper v2 process: its pid, the write end of its stdin (the
/// control and liveness pipe) and its stdout lines.
nonisolated final class ComputerUseHelperV2Child: Sendable {
    let pid: pid_t
    private let input: Mutex<Int32>
    let lines: AsyncStream<Data>

    init(pid: pid_t, input: Int32, lines: AsyncStream<Data>) {
        self.pid = pid
        self.input = Mutex(input)
        self.lines = lines
    }

    /// Writes one control line, off the main actor. False once the pipe is closed.
    @discardableResult
    @concurrent func send(_ line: Data) async -> Bool {
        input.withLock { descriptor in
            guard descriptor >= 0 else { return false }
            return line.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    // concurrency-allow: @concurrent, so never on the main actor; one short control line into a pipe the helper drains.
                    let written = Darwin.write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                    if written <= 0 { if errno == EINTR { continue }; return false }
                    offset += written
                }
                return true
            }
        }
    }

    /// Closes stdin: the helper sees EOF and exits (the same signal it gets
    /// when this app dies).
    func closeInput() {
        input.withLock { descriptor in
            guard descriptor >= 0 else { return }
            close(descriptor)
            descriptor = -1
        }
    }
}

/// Starts the helper v2 executable (a fake in tests).
nonisolated protocol ComputerUseHelperV2Spawning: Sendable {
    func spawn(executable: URL, environment: [String: String], logPath: String) throws -> ComputerUseHelperV2Child
    /// SIGTERM to this exact pid, then reap it.
    func terminate(_ pid: pid_t)
}

/// posix_spawn with macOS responsibility disclaimed, so the helper is its
/// own responsible process: Accessibility and Screen Recording are checked
/// against the helper's code identity (com.cmuxterm.cua.dev in DEV builds),
/// never against cmux, and cmux's shells never inherit them. The helper
/// stays this app's child: its stdin is our pipe, and EOF stops it.
///
/// `responsibility_spawnattrs_setdisclaim` is the libsystem call that
/// upstream Cua Driver and cmux-cua use for the same reason. When it is
/// missing, the helper does not start: starting it without the disclaim
/// would make macOS attribute its permissions to cmux.
nonisolated struct DisclaimedHelperSpawner: ComputerUseHelperV2Spawning {
    typealias DisclaimFunction = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    enum Failure: Error, Equatable {
        case disclaimUnavailable
        case spawn(Int32)
    }

    /// Resolved once from libsystem; tests inject their own.
    let disclaim: DisclaimFunction?

    init(disclaim: DisclaimFunction? = DisclaimedHelperSpawner.systemDisclaim) {
        self.disclaim = disclaim
    }

    static let systemDisclaim: DisclaimFunction? = {
        // RTLD_DEFAULT
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return nil }
        return unsafeBitCast(symbol, to: DisclaimFunction.self)
    }()

    func spawn(executable: URL, environment: [String: String], logPath: String) throws -> ComputerUseHelperV2Child {
        // RED STUB (commit 1): no disclaim check.
        let disclaim = disclaim ?? { _, _ in 0 }
        var toHelper: [Int32] = [-1, -1]
        var toHost: [Int32] = [-1, -1]
        guard pipe(&toHelper) == 0 else { throw Failure.spawn(errno) }
        guard pipe(&toHost) == 0 else {
            close(toHelper[0]); close(toHelper[1])
            throw Failure.spawn(errno)
        }
        _ = fcntl(toHelper[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(toHost[0], F_SETFD, FD_CLOEXEC)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
            close(toHelper[0])
            close(toHost[1])
        }
        posix_spawn_file_actions_adddup2(&actions, toHelper[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, toHost[1], STDOUT_FILENO)
        _ = logPath.withCString { path in
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        }
        // Only stdin, stdout and stderr reach the helper.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        guard disclaim(&attributes, 1) == 0 else {
            close(toHelper[1]); close(toHost[0])
            throw Failure.disclaimUnavailable
        }
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable.path), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        guard status == 0 else {
            close(toHelper[1]); close(toHost[0])
            throw Failure.spawn(status)
        }
        return ComputerUseHelperV2Child(pid: pid, input: toHelper[1], lines: Self.lines(from: toHost[0]))
    }

    func terminate(_ pid: pid_t) {
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
        Self.reap(pid)
    }

    /// Reaps the child off the main thread so it never stays a zombie.
    static func reap(_ pid: pid_t) {
        let thread = Thread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        }
        thread.name = "cua-helper-v2-reap"
        thread.start()
    }

    /// stdout as lines, read on a dedicated thread until EOF.
    /// Only the first lines matter to the host (`ready`); later lines are
    /// read and dropped so the helper never blocks on a full pipe.
    static func lines(from descriptor: Int32) -> AsyncStream<Data> {
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let thread = Thread {
                var pending = Data()
                var bytes = [UInt8](repeating: 0, count: 16 * 1024)
                // concurrency-allow: a dedicated Thread blocked in read(2); the loop ends at EOF or a read error (helper exit).
                while true {
                    // concurrency-allow: dedicated reader Thread, never the main actor.
                    let count = read(descriptor, &bytes, bytes.count)
                    if count < 0, errno == EINTR { continue }
                    if count <= 0 { break }
                    pending.append(contentsOf: bytes[0..<count])
                    while let newline = pending.firstIndex(of: 0x0A) {
                        continuation.yield(Data(pending[pending.startIndex..<newline]))
                        pending.removeSubrange(pending.startIndex...newline)
                    }
                }
                close(descriptor)
                continuation.finish()
            }
            thread.name = "cua-helper-v2-stdout"
            thread.start()
        }
    }
}
