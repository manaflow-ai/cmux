// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxNextCompat
public import Darwin
public import Foundation

/// A signed helper app that holds its own macOS grants (Screen Recording, Accessibility):
/// copied out of this app's bundle
/// (``SignedHelperStaging``: macOS 26 checks Screen Recording for a helper inside an app
/// bundle as the outermost app) and started with responsibility disclaimed
/// (``systemDisclaim``), so macOS checks, prompts for and lists the helper by its own
/// name, never cmux. A grant then restarts at most the helper, never this app.
/// Used by the Screen Sharing helper (plans/cmux-next/screen-sharing-helper.md).
public nonisolated struct SignedHelperLaunch: Sendable {
    public enum Failure: Error, Equatable {
        /// libsystem has no `responsibility_spawnattrs_setdisclaim`: starting the helper without
        /// it would make macOS attribute its grants to cmux, so it does not start.
        case disclaimUnavailable
        case spawn(Int32)
    }

    private let staging: SignedHelperStaging

    /// The Screen Sharing helper's copy, one per app build (`bundleID`'s scope).
    public static func screenSharing(bundleID: String = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app") -> SignedHelperLaunch {
        SignedHelperLaunch(staging: .screenSharing(bundleID: bundleID))
    }

    init(staging: SignedHelperStaging) {
        self.staging = staging
    }

    /// The verified copy of the helper app `source` to launch (made or replaced when the source
    /// changed); nil when it cannot be made or does not pass its signature check.
    @concurrent public func stage(_ source: URL) async -> URL? {
        await staging.stage(source)
    }

    /// posix_spawn `executable` with `arguments` and responsibility disclaimed. Its stdin, stdout
    /// and stderr are `stdin`, `stdout` and `stderr` (the caller keeps and closes its own ends);
    /// no other descriptor reaches it. The environment is this process's. The caller reaps it
    /// (``reap(_:)``) or waits for it.
    public static func spawn(executable: URL, arguments: [String], stdin: Int32, stdout: Int32, stderr: Int32) throws -> pid_t {
        guard let disclaim = Self.systemDisclaim else { throw Failure.disclaimUnavailable }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, stdin, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO)
        // Only stdin, stdout and stderr reach the helper.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        guard disclaim(&attributes, 1) == 0 else { throw Failure.disclaimUnavailable }
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.sorted { $0.key < $1.key }
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = blockingPosixSpawn(&pid, executable.path, &actions, &attributes, argv, envp)
        guard status == 0 else { throw Failure.spawn(status) }
        return pid
    }

    /// Reaps `pid` off the caller's thread when it exits, so it never stays a zombie.
    public static func reap(_ pid: pid_t) {
        let thread = Thread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        }
        thread.name = "signed-helper-reap"
        thread.start()
    }

    typealias DisclaimFunction = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    /// libsystem's `responsibility_spawnattrs_setdisclaim`, resolved once; nil when missing.
    static let systemDisclaim: DisclaimFunction? = {
        // RTLD_DEFAULT
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return nil }
        return unsafeBitCast(symbol, to: DisclaimFunction.self)
    }()
}
