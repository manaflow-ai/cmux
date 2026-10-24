package import Darwin
import Foundation

/// The app's open-file limit (RLIMIT_NOFILE).
///
/// launchd starts an app with a soft limit of 256 descriptors (`launchctl limit maxfiles`). Every
/// Chromium tab costs the browser process several descriptors (its renderer's IPC channels, shared
/// memory, the GPU and network services' pipes), and every terminal, socket and watched file costs
/// more: at 80-100 Chromium tabs the app ran out, and Chromium aborted (activation-perf, 150
/// workspaces, cmux10s and cmux7s, 2026-10-23). Chrome raises its own limit at start; the cmux
/// daemons raise theirs (cmux-pty `raise_open_file_limit`). The app does the same, first thing
/// in `main`, before CefInitialize and before any thread.
///
/// Every program a person runs through cmux sees the limit of the environment that launched cmux
/// (``Change/launchLimit``), the same `ulimit -n` in a terminal and in an agent chat:
/// - Terminals, and the hooks, plugins and Chief brains the daemons run: the app names the launch
///   limit to every cmux-tui owner it starts, and only to them (``daemonEnvironment(launchLimit:)``,
///   ``originalSoftLimitKey``); the owner records it and removes the variable, and its holder,
///   terminal hosts and process scopes give it back.
/// - Agent chats: the app starts its acpmux daemon at the launch limit (its launch shell runs
///   `ulimit -S -n` before the daemon's `exec`, `AcpmuxDaemonLauncher`), as launchd starts a
///   standalone one. The daemon raises its own limit at start (acpmux `open_file_limit::raise`);
///   its agents get the limit it started with only where acpmux sets it back between their fork
///   and `exec` (open: acpmux does not yet, so agent tool shells still see its raised limit).
///
/// Which children keep the raised limit, on purpose (this list is the one place that says so):
/// - Chromium's helpers (GPU, network, renderers): they need it.
/// - The app's other short-lived direct children (`ProcessRunner` helpers such as git and ssh
///   probes, and the login-shell capture `$SHELL -l -i -c 'env -0'`): Darwin's `posix_spawn`
///   cannot set a child's limits, so lowering it needs a shell between spawn and `exec`. A raised
///   soft limit gives a program no descriptor at or above `FD_SETSIZE` (1024) by itself; only a
///   program that opens more than 1024 files can reach `select(2)`'s abort, where 256 would have
///   stopped it with EMFILE instead. A daemon a login rc file starts from the capture (ssh-agent,
///   gpg-agent) keeps the raised limit for that reason.
///
/// The syscalls are injected (``init(ceiling:read:write:perProcessCap:)``); a test passes its own:
///
/// ```swift
/// let limit = OpenFileLimit(read: { .success((soft: 256, hard: 4_096)) }, write: { _, _ in .success(()) },
///                           perProcessCap: { 24_576 })
/// #expect(limit.raise().change == .init(before: 256, after: 4_096))
/// ```
package struct OpenFileLimit: Sendable {
    /// The environment variable the cmux daemon, holder and terminal hosts read for the soft limit
    /// every shell gets back (cmux-pty `LAUNCH_SOFT_LIMIT_ENV`, cmux-holder `NOFILE_SOFT_ENV`).
    package static let originalSoftLimitKey = "CMUX_TUI_HOST_NOFILE_SOFT"
    /// `OPEN_MAX` (<sys/syslimits.h>): the highest soft limit an older kernel accepts, and the
    /// per-process cap when `kern.maxfilesperproc` cannot be read.
    package static let openMax: rlim_t = 10_240

    /// A soft and a hard limit.
    package typealias Limits = (soft: rlim_t, hard: rlim_t)

    /// A getrlimit or setrlimit the kernel refused, with the errno it set.
    package struct Refusal: Error, Equatable {
        package var errno: Int32

        package init(errno: Int32) {
            self.errno = errno
        }
    }

    /// The soft limit the app asks for, as far as the hard limit and `kern.maxfilesperproc`
    /// allow: the cmux daemons' ceiling (cmux-pty `OPEN_FILE_LIMIT_CEILING`).
    package let ceiling: rlim_t
    private let read: @Sendable () -> Result<Limits, Refusal>
    private let write: @Sendable (_ soft: rlim_t, _ hard: rlim_t) -> Result<Void, Refusal>
    private let perProcessCap: @Sendable () -> rlim_t

    /// This process's limit, through the real syscalls.
    package init(ceiling: rlim_t = 65_536) {
        self.init(ceiling: ceiling, read: { Self.systemLimits() }, write: { Self.setSystemSoftLimit($0, hard: $1) },
                  perProcessCap: { Self.systemPerProcessCap() })
    }

    /// A limit with its own syscalls, for tests.
    ///
    /// - Parameter ceiling: The highest soft limit to ask for.
    /// - Parameter read: Reads the soft and hard limit (getrlimit).
    /// - Parameter write: Sets the soft limit under the hard limit (setrlimit).
    /// - Parameter perProcessCap: `kern.maxfilesperproc`: setrlimit refuses a soft limit above it,
    ///   even under an unlimited hard limit.
    package init(ceiling: rlim_t = 65_536,
                 read: @escaping @Sendable () -> Result<Limits, Refusal>,
                 write: @escaping @Sendable (_ soft: rlim_t, _ hard: rlim_t) -> Result<Void, Refusal>,
                 perProcessCap: @escaping @Sendable () -> rlim_t) {
        self.ceiling = ceiling
        self.read = read
        self.write = write
        self.perProcessCap = perProcessCap
    }

    /// The soft limit before and after ``raise()``.
    package struct Change: Equatable, Sendable {
        package var before: rlim_t
        package var after: rlim_t

        package init(before: rlim_t, after: rlim_t) {
            self.before = before
            self.after = after
        }

        /// The soft limit the programs cmux runs for a person get back: `before` when the raise
        /// changed the limit, else nil (they inherit the app's limit, which is the launch one).
        package var launchLimit: rlim_t? {
            after > before ? before : nil
        }
    }

    /// What every cmux-tui owner the app starts gets in its own environment, and nothing else:
    /// ``originalSoftLimitKey`` with `launchLimit` (``Change/launchLimit``), else nothing. The owner
    /// records it and removes the variable, so its shells, hooks and plugins get the launch limit
    /// back; a terminal's env never carries it.
    package static func daemonEnvironment(launchLimit: rlim_t?) -> [String: String] {
        launchLimit.map { [originalSoftLimitKey: String($0)] } ?? [:]
    }

    /// What one ``raise()`` did.
    package struct Report: Equatable, Sendable {
        /// The soft limit before and after; nil when it could not be read.
        package var change: Change?
        /// The one line the launch logs, on every path, so a launch that stays at 256 says why:
        /// `cmux: open-file limit 256 -> 65536`, `cmux: open-file limit 65536 (kept)`,
        /// `cmux: open-file limit stays 256 (setrlimit 65536: errno 1)` or
        /// `cmux: open-file limit unknown (getrlimit: errno 22)`.
        package var line: String

        package init(change: Change?, line: String) {
            self.change = change
            self.line = line
        }
    }

    /// Raises the soft limit to `min(hard, ceiling, kern.maxfilesperproc)`, falling back to
    /// `OPEN_MAX` when the kernel refuses more. Never lowers it and never changes the hard limit.
    package func raise() -> Report {
        let limits: Limits
        switch read() {
        case .success(let value):
            limits = value
        case .failure(let refusal):
            return Report(change: nil, line: "cmux: open-file limit unknown (getrlimit: errno \(refusal.errno))")
        }
        let (soft, hard) = limits
        let target = min(hard, ceiling, perProcessCap())
        guard target > soft else {
            return Report(change: Change(before: soft, after: soft), line: "cmux: open-file limit \(soft) (kept)")
        }
        switch write(target, hard) {
        case .success:
            return Report(change: Change(before: soft, after: target), line: "cmux: open-file limit \(soft) -> \(target)")
        case .failure(let refusal):
            let refused = "setrlimit \(target): errno \(refusal.errno)"
            if target > Self.openMax, Self.openMax > soft, case .success = write(Self.openMax, hard) {
                return Report(change: Change(before: soft, after: Self.openMax),
                              line: "cmux: open-file limit \(soft) -> \(Self.openMax) (\(refused))")
            }
            return Report(change: Change(before: soft, after: soft), line: "cmux: open-file limit stays \(soft) (\(refused))")
        }
    }

    private static func systemLimits() -> Result<Limits, Refusal> {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return .failure(Refusal(errno: errno)) }
        return .success((soft: limit.rlim_cur, hard: limit.rlim_max))
    }

    private static func setSystemSoftLimit(_ soft: rlim_t, hard: rlim_t) -> Result<Void, Refusal> {
        var limit = rlimit(rlim_cur: soft, rlim_max: hard)
        guard setrlimit(RLIMIT_NOFILE, &limit) == 0 else { return .failure(Refusal(errno: errno)) }
        return .success(())
    }

    private static func systemPerProcessCap() -> rlim_t {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.maxfilesperproc", &value, &size, nil, 0) == 0 && value > 0 ? rlim_t(value) : openMax
    }
}
