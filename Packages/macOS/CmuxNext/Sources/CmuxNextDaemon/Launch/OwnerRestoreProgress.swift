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
        /// Counts reports of this launcher (``OwnerRestoreProgress/note(_:)`` sets it): a reader can tell a report
        /// it already judged from a newer one.
        public internal(set) var sequence: UInt64 = 0

        public init(pid: Int32? = nil, jobs: [LongJob] = []) {
            self.pid = pid
            self.jobs = jobs
        }

        /// The newest progress or heartbeat of its jobs (`updated_ms`), nil with none.
        public var lastJobUpdateMs: Int64? { jobs.map(\.updatedMs).max() }
    }

    private struct Reports {
        var current: Report?
        var sequence: UInt64 = 0
        var observers: [@Sendable (Report) -> Void] = []
    }

    private let state = Mutex(Reports())

    public init() {}

    /// The last report (nil before any).
    public var current: Report? { state.withLock { $0.current } }

    /// Calls `observer` with every later report, on the reporting thread (off the main actor).
    public func observe(_ observer: @escaping @Sendable (Report) -> Void) {
        state.withLock { $0.observers.append(observer) }
    }

    func note(_ report: Report) {
        let (observers, stamped) = state.withLock { state -> ([@Sendable (Report) -> Void], Report) in
            state.sequence += 1
            var stamped = report
            stamped.sequence = state.sequence
            state.current = stamped
            return (state.observers, stamped)
        }
        for observer in observers { observer(stamped) }
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

    /// The file of `session` under `stateDirectory`, or under cmux-tui's own root when the launcher names
    /// none (`CMUX_TUI_STATE_DIR`, else `~/Library/Application Support/cmux-tui/sessions`).
    static func url(session: String, stateDirectory: URL?,
                    environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let root = stateDirectory
            ?? environment["CMUX_TUI_STATE_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? CloudLinkLauncher.defaultStateRoot()
        return root?.appendingPathComponent(storageComponent(session: session), isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// How long an owner's jobs may go without an `updated_ms` change and still count as making progress:
    /// cmux-tui's `RESTORE_STALL` (a live job steps or beats at least every 5 s).
    static let stall: Int64 = 120_000

    /// The jobs of a live owner that is making progress: nil when the file is missing or does not parse, its
    /// process is gone, or neither the file nor any job changed within ``stall`` of `nowMs` (a wedged owner
    /// whose process lives on is a failure, not a restore).
    static func read(_ url: URL, nowMs: Int64 = Int64(exactly: (Date().timeIntervalSince1970 * 1000).rounded()) ?? 0)
        -> OwnerRestoreProgress.Report? {
        guard let data = try? Data(blockingContentsOf: url), let list = try? JSONDecoder().decode(LongJobList.self, from: data),
              let pid = list.pid, pid > 0, isAlive(pid) else { return nil }
        let report = OwnerRestoreProgress.Report(pid: pid, jobs: list.jobs)
        guard let newest = [list.updatedMs, report.lastJobUpdateMs].compactMap(\.self).max(), nowMs - newest <= stall else {
            return nil
        }
        return report
    }

    /// Whether `pid` names a running process (a zero signal: EPERM means it runs as another user).
    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
