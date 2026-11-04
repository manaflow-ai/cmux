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
/// Programs in a terminal must still see the limit of the environment that launched cmux: the
/// daemon, its holder and its terminal hosts give every shell the soft limit named by
/// ``originalSoftLimitKey`` (cmux-holder `NOFILE_SOFT_ENV`); the app passes it in the daemon's and its
/// terminals' environment (``Change/childEnvironment``, `AppEnvironment.terminalEnvironment`).
package struct OpenFileLimit {
    /// The environment variable the cmux daemon, holder and terminal hosts read for the soft limit
    /// every shell gets back (cmux-holder `NOFILE_SOFT_ENV`).
    package static let originalSoftLimitKey = "CMUX_TUI_HOST_NOFILE_SOFT"

    /// The soft limit the app asks for, as far as the hard limit and `kern.maxfilesperproc`
    /// allow: the cmux daemons' ceiling (cmux-pty `OPEN_FILE_LIMIT_CEILING`).
    package var ceiling: rlim_t = 65_536
    /// Reads the soft and hard limit (getrlimit); a test passes its own.
    package var read: () -> (soft: rlim_t, hard: rlim_t)? = {
        var limit = rlimit()
        return getrlimit(RLIMIT_NOFILE, &limit) == 0 ? (limit.rlim_cur, limit.rlim_max) : nil
    }
    /// Sets the soft limit under `hard` (setrlimit); true when it took.
    package var write: (_ soft: rlim_t, _ hard: rlim_t) -> Bool = { soft, hard in
        var limit = rlimit(rlim_cur: soft, rlim_max: hard)
        return setrlimit(RLIMIT_NOFILE, &limit) == 0
    }
    /// `kern.maxfilesperproc`: setrlimit refuses a soft limit above it, even under an unlimited
    /// hard limit. `OPEN_MAX` (10240) when it cannot be read.
    package var perProcessCap: () -> rlim_t = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.maxfilesperproc", &value, &size, nil, 0) == 0 && value > 0 ? rlim_t(value) : 10_240
    }

    package init() {}

    /// The fewest open files the app must be allowed before it starts Chromium. Chromium treats a
    /// failed pipe on its child-launch path as fatal
    /// (`SeatbeltExecClient: pipe failed`, sandbox/mac/seatbelt_exec.cc), and under a hard limit of
    /// 256 the browser process ran out within 6 s of a launch and aborted the whole app (chaos fuzz
    /// row h, cmux21, 2026-10-31). Measured on cmux21 (2026-10-31 12:53Z, build of feat d1f0e63691a0,
    /// the restored session plus 5 Chromium tabs, 25 s per launch): the app process peaked at 264-270
    /// open descriptors, and hard limits of 512 (6 launches), 1024 (6) and 2048 (5) gave 0 aborts and
    /// no EMFILE line. 1024 is the lowest clean limit, 512, with a 2x margin for more tabs and
    /// services. A launch from Finder, the Dock or `open` raises past `OPEN_MAX` (10240), so only a
    /// launch under a lowered hard limit (`ulimit -n` in a shell sets both) is below this floor.
    package static let chromiumFloor: rlim_t = 1_024

    /// The soft limit when it is below ``chromiumFloor``: Chromium must not start in this process.
    /// Nil when it may start, or when the limit cannot be read. Read after ``raise()``.
    package func chromiumShortfall() -> rlim_t? {
        guard let (soft, _) = read(), soft < Self.chromiumFloor else { return nil }
        return soft
    }

    /// The soft limit before and after ``raise()``.
    package struct Change: Equatable {
        package var before: rlim_t
        package var after: rlim_t

        package init(before: rlim_t, after: rlim_t) {
            self.before = before
            self.after = after
        }

        /// What the daemon and its terminal hosts read to give every shell the launch limit back:
        /// ``OpenFileLimit/originalSoftLimitKey`` when the raise changed the limit, else nothing.
        package var childEnvironment: [String: String] {
            after > before ? [OpenFileLimit.originalSoftLimitKey: String(before)] : [:]
        }
    }

    /// Raises the soft limit to `min(hard, ceiling, kern.maxfilesperproc)`, falling back to
    /// `OPEN_MAX` when the kernel refuses more. Never lowers it and never changes the hard limit.
    /// Nil when the limit could not be read.
    @discardableResult
    package func raise() -> Change? {
        guard let (soft, hard) = read() else { return nil }
        let target = min(hard, ceiling, perProcessCap())
        guard target > soft else { return Change(before: soft, after: soft) }
        let openMax: rlim_t = 10_240
        let after = write(target, hard) ? target : target > openMax && openMax > soft && write(openMax, hard) ? openMax : soft
        if after > soft {
            FileHandle.standardError.write(Data("cmux: open-file limit \(soft) -> \(after)\n".utf8))
        }
        return Change(before: soft, after: after)
    }
}
