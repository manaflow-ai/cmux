import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "timing")

/// Time to a usable Mac, step by step: each step is logged once per
/// attempt as `timing <attempt> <step> +<ms since the attempt> (<ms since
/// process start>)` under the `timing` category. An attempt starts at
/// launch, and again at each foreground (`begin`). verify/fast-connect.md
/// reads these lines.
public final class ConnectTimeline: @unchecked Sendable {
    public static let shared = ConnectTimeline()

    private let lock = NSLock()
    private let processStart: Date
    private var attemptStart: Date
    private var attempt = "launch"
    private var seen: Set<String> = []

    init() {
        processStart = Self.processStartDate() ?? Date()
        attemptStart = processStart
    }

    /// A new attempt (say `foreground`) measured from now.
    public func begin(_ name: String) {
        lock.withLock {
            attempt = name
            attemptStart = Date()
            seen = []
        }
        log.info("timing \(name, privacy: .public) begin (\(Self.ms(Date().timeIntervalSince(self.processStart)), privacy: .public) since process start)")
    }

    /// Records `step` once per attempt.
    public func mark(_ step: String, detail: String = "") {
        let now = Date()
        let (attempt, since, first) = lock.withLock { () -> (String, TimeInterval, Bool) in
            (self.attempt, now.timeIntervalSince(attemptStart), seen.insert(step).inserted)
        }
        guard first else { return }
        let total = now.timeIntervalSince(processStart)
        log.info("timing \(attempt, privacy: .public) \(step, privacy: .public) +\(Self.ms(since), privacy: .public) (\(Self.ms(total), privacy: .public)) \(detail, privacy: .public)")
    }

    /// Records a UI event every time it happens (not once per attempt), for
    /// latencies the E2E rig maps onto its screen recording: `timing event
    /// <step> (<ms since process start>) <detail>`. The log line's own
    /// timestamp is the event time.
    public func event(_ step: String, detail: String = "") {
        let total = Date().timeIntervalSince(processStart)
        log.info("timing event \(step, privacy: .public) (\(Self.ms(total), privacy: .public)) \(detail, privacy: .public)")
    }

    /// Seconds since the process started.
    public var sinceProcessStart: TimeInterval { Date().timeIntervalSince(processStart) }

    /// Milliseconds since the current attempt began.
    public var elapsedMillis: Double {
        lock.withLock { Date().timeIntervalSince(attemptStart) * 1000 }
    }

    static func ms(_ seconds: TimeInterval) -> String {
        String(format: "%.0fms", seconds * 1000)
    }

    private static func processStartDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}
