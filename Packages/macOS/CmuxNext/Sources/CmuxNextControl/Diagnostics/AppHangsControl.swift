public import CmuxNextSettings
import Darwin

/// `app.hangs` (`cmux app hangs`, every build): the main-thread watchdog's stall counts, read-only,
/// so a Release or Nightly app tells how often its main thread stalled past 100 and 250 ms
/// without a DEV build's `debug.hangs`. The watchdog records every stall past its threshold
/// (50 ms) in every build already; this only reads its lock-protected counters, off the main
/// actor, so it answers while the main thread is stalled.
///
/// The reply carries numbers and code names only: each record's top frames are symbol names (or,
/// in a frame the build's names do not cover, its image file name and offset for the dSYM), its
/// verdict and the scheduled task's owner and class. No stack text, page, title or path: nothing
/// a person typed or opened. It clears nothing (`debug.hangs` `clear` stays DEV-only).
public enum AppHangsControl {
    /// The control method (`APP_HANGS_METHOD` in cmux-tui's cli/app.rs; a test holds the two equal).
    public static let method = "app.hangs"
    /// The stall lengths counted on their own (`over_100ms`, `over_250ms`).
    public static let countedThresholds: [Duration] = [.milliseconds(100), .milliseconds(250)]
    /// Records a reply carries by default, and at most.
    public static let defaultLimit = 20
    /// Frames each record carries, innermost first.
    public static let frameLimit = 8

    /// The reply for `watchdog` (nil: none installed), with at most `limit` newest stall records.
    public static func reply(watchdog: MainThreadWatchdog?, limit requested: Int?) -> JSONValue {
        guard let watchdog else {
            return ["installed": false, "count": 0, "over_100ms": 0, "over_250ms": 0, "records": []]
        }
        let limit = min(max(requested ?? defaultLimit, 0), watchdog.log.capacity)
        let summary = watchdog.log.summary
        let records = watchdog.log.records().filter { $0.kind == .stall }.suffix(limit)
        var object: [String: JSONValue] = [
            "installed": .bool(watchdog.isRunning),
            "threshold_ms": .number(watchdog.configuration.threshold.fractionalMilliseconds),
            "count": JSONValue(summary.count),
            "over_100ms": JSONValue(summary.over100Count),
            "over_250ms": JSONValue(summary.over250Count),
            "max_ms": .number(summary.maxDuration.fractionalMilliseconds),
            "total_ms": .number(summary.totalDuration.fractionalMilliseconds),
            "records": .array(records.map(record)),
        ]
        // The main thread's CPU over wall time since the watchdog started: its busy share
        // (readers diff two reads for a window).
        if let busy = watchdog.busySinceStart {
            object["since_start_ms"] = .number(busy.wall.fractionalMilliseconds)
            object["main_thread_cpu_ms"] = .number(busy.cpu.fractionalMilliseconds)
            object["main_thread_busy_share"] = .number(busy.share)
        }
        return .object(object)
    }

    /// One stall: its numbers, verdict, the scheduled task its sample caught, and its top frames.
    static func record(_ record: HangRecord) -> JSONValue {
        var object: [String: JSONValue] = [
            "sequence": JSONValue(Int(truncatingIfNeeded: record.sequence)),
            "start_uptime_ns": .number(Double(record.startUptimeNanos)),
            "duration_ms": .number(record.duration.fractionalMilliseconds),
            "cpu_ms": .number(record.cpu.fractionalMilliseconds),
            "frames": .array(StackSymbolicator().frames(for: Array(record.addresses.prefix(frameLimit))).map(frame)),
        ]
        for key in detailKeys { if let value = record.details[key] { object[key] = value } }
        return .object(object)
    }

    /// The stall details a reply passes on: numbers and code names (``MainThreadWatchdog``'s
    /// `recordStall`, ``MainThreadWatchdog/details(of:)``).
    static let detailKeys = ["verdict", "source", "host_load_1m", "host_cores", "task_owner", "task_class", "task_budget_ms", "task_started_ms"]

    /// A frame's symbol name; for a frame with none, its image's file name and offset (the dSYM resolves it).
    static func frame(_ frame: HangFrame) -> JSONValue {
        .object([
            "symbol": frame.symbol.map(JSONValue.string) ?? .null,
            "image": frame.image.map(JSONValue.string) ?? .null,
            "image_offset": frame.imageOffset.map { .number(Double($0)) } ?? .null,
        ])
    }
}
