#if DEBUG
import Dispatch
import Foundation

/// Low-overhead, opt-in latency stamps for DEBUG host builds.
enum HostLatencyTrace {
    static let isEnabled =
        ProcessInfo.processInfo.environment["CMUX_LATENCY_TRACE"] == "1"
        || UserDefaults.standard.bool(forKey: "cmux.debug.latency-trace")

    @inline(__always)
    static func stamp(
        _ stage: StaticString,
        _ fields: @autoclosure () -> String = ""
    ) {
        guard isEnabled else { return }
        write(stage, uptimeMicroseconds: nowUptimeMicroseconds(), fields: fields())
    }

    @inline(__always)
    static func captureTime() -> UInt64? {
        guard isEnabled else { return nil }
        return nowUptimeMicroseconds()
    }

    @inline(__always)
    static func stampElapsed(
        _ stage: StaticString,
        since start: UInt64?,
        _ fields: (_ elapsedMicroseconds: UInt64) -> String
    ) {
        guard let start else { return }
        let completionTime = nowUptimeMicroseconds()
        write(
            stage,
            uptimeMicroseconds: completionTime,
            fields: fields(completionTime &- start)
        )
    }

    @inline(__always)
    private static func nowUptimeMicroseconds() -> UInt64 {
        // Simulator uptime is in the host Mac clock domain, so simulator and
        // Mac stamps are directly comparable. A physical iPhone is not.
        DispatchTime.now().uptimeNanoseconds / 1_000
    }

    @inline(__always)
    private static func write(
        _ stage: StaticString,
        uptimeMicroseconds: UInt64,
        fields: String
    ) {
        let suffix = fields.isEmpty ? "" : " \(fields)"
        cmuxDebugLog("LAT \(stage) t=\(uptimeMicroseconds)\(suffix)")
    }
}
#endif
