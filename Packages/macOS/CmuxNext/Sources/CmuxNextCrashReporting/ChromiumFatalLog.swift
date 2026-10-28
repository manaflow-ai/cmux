public import Foundation

/// Where the process that ran `CefInitialize` wrote its Chromium log, and which of its lines are its own
/// (plans/cmux-next/chrome-parity/p09-observability.md, task 084). Chromium runs in one of two processes, each
/// with its own log and its own end:
///
/// - ``Role/app``: in process. A Chromium `FATAL` ends the app, so the line goes on that run's crash event, sent
///   at the next launch. The log is `cef.log`, or `cef.previous.log` once this launch's Chromium start moved it
///   aside (`CEFProfileStorage.keepPreviousLog`).
/// - ``Role/chromiumHost``: in the Chromium host, whose `--log-file` is its own (`ChromiumHostConfiguration.logFile`).
///   The app outlives it, so its line goes on the event of the host's end (task 104).
///
/// Only a file last written while that process ran counts, and only that process's lines: helpers write to the
/// same log, and the other role's log, or an older run's, is never read.
public struct ChromiumFatalLog: Sendable, Equatable {
    /// The process that ran `CefInitialize`.
    public enum Role: Sendable, Equatable {
        case app
        case chromiumHost
    }

    public var role: Role
    /// The files that may hold the run's log, in any order: the newest one written in ``window`` is read.
    public var candidates: [URL]
    /// The process's pid, as its log lines name it.
    public var pid: Int32
    /// From the process's start until its end.
    public var window: Range<Date>

    /// The previous app run's log (`logFile`, or `previousLogFile` once this launch moved it aside), when that run
    /// ended uncleanly; nil after a requested or normal quit, or with no time between its launch and `now`.
    public static func app(pid: Int32, launched: Date, endedUncleanly: Bool, now: Date, logFile: URL,
                           previousLogFile: URL) -> ChromiumFatalLog? {
        guard endedUncleanly, launched < now else { return nil }
        return ChromiumFatalLog(role: .app, candidates: [logFile, previousLogFile], pid: pid, window: launched ..< now)
    }

    /// A Chromium host's log, from its start until its end.
    public static func chromiumHost(logFile: URL, pid: Int32, started: Date, ended: Date) -> ChromiumFatalLog? {
        guard started < ended else { return nil }
        return ChromiumFatalLog(role: .chromiumHost, candidates: [logFile], pid: pid, window: started ..< ended)
    }

    /// The process's last `FATAL` line, URLs removed. Blocking file work (at most 64 KiB): off the main thread.
    public func read() -> CEFFatalLine? {
        CEFFatalLine.read(candidates: candidates, writtenIn: window, pid: pid)
    }
}
