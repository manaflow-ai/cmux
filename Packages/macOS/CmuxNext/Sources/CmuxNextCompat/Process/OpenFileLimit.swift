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
