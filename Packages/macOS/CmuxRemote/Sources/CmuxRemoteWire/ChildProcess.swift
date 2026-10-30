// SPDX-License-Identifier: GPL-3.0-or-later
public import Darwin
public import Foundation
import os

/// A started child: its pid and the parent's ends of its stdin and stdout.
public struct ChildProcess: Sendable {
    public let pid: pid_t
    /// Write end of the child's stdin; closing it is the child's stop signal.
    public let stdin: Int32
    /// Read end of the child's stdout.
    public let stdout: Int32

    /// posix_spawn of `executable` with `arguments` and exactly `environment`;
    /// stdin and stdout are pipes, stderr appends to `logPath`; nothing else is
    /// inherited. A normal child of this process: macOS attributes its
    /// Accessibility and Screen Recording checks to this process.
    public static func spawn(executable: String, arguments: [String], environment: [String: String],
                             logPath: String) throws -> ChildProcess {
        var toChild: [Int32] = [-1, -1]
        var fromChild: [Int32] = [-1, -1]
        guard pipe(&toChild) == 0 else { throw LocalSocket.Failure.system("pipe", errno) }
        guard pipe(&fromChild) == 0 else {
            close(toChild[0]); close(toChild[1])
            throw LocalSocket.Failure.system("pipe", errno)
        }
        _ = fcntl(toChild[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fromChild[0], F_SETFD, FD_CLOEXEC)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
            close(toChild[0])
            close(fromChild[1])
        }
        posix_spawn_file_actions_adddup2(&actions, toChild[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, fromChild[1], STDOUT_FILENO)
        _ = logPath.withCString { path in
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard status == 0 else {
            close(toChild[1]); close(fromChild[0])
            throw LocalSocket.Failure.system("posix_spawn", status)
        }
        return ChildProcess(pid: pid, stdin: toChild[1], stdout: fromChild[0])
    }

    /// Calls `onExit` once with the exit status, on a dedicated thread, after reaping `pid`.
    public static func watch(_ pid: pid_t, name: String, onExit: @escaping @Sendable (Int32) -> Void) {
        let thread = Thread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            onExit(status)
        }
        thread.name = name
        thread.start()
    }
}

/// Copies bytes both ways between two descriptors until either side ends,
/// then shuts the other side down. Each direction runs on its own thread.
public struct BytePump: Sendable {
    public init() {}

    /// `first` gets `prefix` before anything read from `second`.
    public static func splice(_ first: Int32, _ second: Int32, prefixForSecond: Data = Data(), name: String,
                              onEnd: @escaping @Sendable () -> Void = {}) {
        let ended = OSAllocatedUnfairLockBox()
        let finish: @Sendable () -> Void = {
            guard ended.markFirst() else { return }
            _ = shutdown(first, SHUT_RDWR)
            _ = shutdown(second, SHUT_RDWR)
            onEnd()
        }
        _ = LineChannel.writeAll(second, prefixForSecond)
        for (source, target) in [(first, second), (second, first)] {
            let thread = Thread {
                var bytes = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let count = read(source, &bytes, bytes.count)
                    if count < 0, errno == EINTR { continue }
                    if count <= 0 || !LineChannel.writeAll(target, Data(bytes[0..<count])) { break }
                }
                finish()
            }
            thread.name = name
            thread.start()
        }
    }
}

extension BytePump {
    /// Copies bytes from `source` to `target` on a dedicated thread until
    /// `source` ends or `target` refuses them, then calls `onEnd`.
    public static func forward(from source: Int32, to target: Int32, name: String, onEnd: @escaping @Sendable () -> Void) {
        let thread = Thread {
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(source, &bytes, bytes.count)
                if count < 0, errno == EINTR { continue }
                if count <= 0 || !LineChannel.writeAll(target, Data(bytes[0..<count])) { break }
            }
            onEnd()
        }
        thread.name = name
        thread.start()
    }
}

/// A flag that only the first caller sets, for the pump's two threads.
final class OSAllocatedUnfairLockBox: Sendable {
    private let done = OSAllocatedUnfairLock(initialState: false)

    func markFirst() -> Bool {
        done.withLock { done in
            defer { done = true }
            return !done
        }
    }
}
