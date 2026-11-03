import CmuxNextCompat
import Darwin
public import CmuxNextWakeups
import Foundation

/// What the local session owner said about its restore while the app waited for it
/// (plans/cmux-next/long-jobs-DESIGN.md): the jobs of the last `server ensure --restore-progress`
/// line, or of the owner's `long-jobs.json` after a parked `identify`. Shared by every copy of one
/// launcher, like ``EnsureOutcome``; ``DaemonService`` turns each report into
/// `DaemonStartupState.restoring`.
public final class OwnerRestoreProgress: Sendable {
    /// One report: the owner is alive and restoring.
    public struct Report: Sendable, Equatable {
        /// The owner's pid, when it said.
        public var pid: Int32?
        /// The jobs it named (empty: it restores with none to name, an older daemon).
        public var jobs: [LongJob]

        public init(pid: Int32? = nil, jobs: [LongJob] = []) {
            self.pid = pid
            self.jobs = jobs
        }
    }

    private struct State {
        var current: Report?
        var observers: [@Sendable (Report) -> Void] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// The last report (nil before any).
    public var current: Report? { state.withLock { $0.current } }

    /// Calls `observer` with every later report, on the reporting thread (off the main actor).
    public func observe(_ observer: @escaping @Sendable (Report) -> Void) {
        state.withLock { $0.observers.append(observer) }
    }

    func note(_ report: Report) {
        let observers = state.withLock { state -> [@Sendable (Report) -> Void] in
            state.current = report
            return state.observers
        }
        for observer in observers { observer(report) }
    }

    /// One `server ensure --restore-progress` stdout line: `{"progress":"restoring", "pid", "waited_ms", "jobs"?}`.
    /// Nil for any other line (the result, a partial write).
    static func parse(progressLine line: String) -> Report? {
        struct Line: Decodable {
            var progress: String?
            var pid: Int32?
            var jobs: [LongJob]?
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), let parsed = try? JSONDecoder().decode(Line.self, from: Data(trimmed.utf8)),
              parsed.progress == "restoring" else { return nil }
        return Report(pid: parsed.pid, jobs: parsed.jobs ?? [])
    }
}

/// The owner's long-jobs status file (`long-jobs.json` in its session state directory,
/// `{"version":1,"pid":N,"updated_ms":T,"jobs":[...]}`): readable while its socket parks connections.
struct OwnerJobsFile {
    static let fileName = "long-jobs.json"

    /// cmux-tui's directory name for `session` under its state root (`session_storage_component`
    /// in cmux-tui-core's workspace_registry.rs): up to 48 kept characters (others as `_`), then a
    /// dash and the FNV-1a 64 hash of the name in 16 hex digits.
    static func storageComponent(session: String) -> String {
        var readable = ""
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in session.utf8 {
            hash ^= UInt64(truncatingIfNeeded: byte)
            hash = hash &* 0x0000_0100_0000_01b3
            guard readable.utf8.count < 48 else { continue }
            let kept = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a)
                || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
            readable.append(kept ? Character(Unicode.Scalar(byte)) : "_")
        }
        if readable.isEmpty { readable = "session" }
        let hex = String(hash, radix: 16)
        return "\(readable)-\(String(repeating: "0", count: max(0, 16 - hex.count)))\(hex)"
    }

    /// The file of `session` under `stateDirectory` (nil without a state directory).
    static func url(session: String, stateDirectory: URL?) -> URL? {
        stateDirectory?.appendingPathComponent(storageComponent(session: session), isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// The jobs of a live owner: nil when the file is missing, does not parse, or its process is gone.
    static func read(_ url: URL) -> OwnerRestoreProgress.Report? {
        guard let data = try? Data(blockingContentsOf: url), let list = try? JSONDecoder().decode(LongJobList.self, from: data),
              let pid = list.pid, pid > 0, isAlive(pid) else { return nil }
        return OwnerRestoreProgress.Report(pid: pid, jobs: list.jobs)
    }

    /// Whether `pid` names a running process (a zero signal: EPERM means it runs as another user).
    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
