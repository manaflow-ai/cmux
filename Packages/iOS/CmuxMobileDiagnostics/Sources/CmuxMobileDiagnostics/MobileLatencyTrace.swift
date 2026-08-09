import Dispatch
import Foundation

/// Low-overhead, opt-in latency stamps for DEBUG mobile builds.
public enum MobileLatencyTrace {
    #if DEBUG
    private static let writer = MobileLatencyTraceWriter(capacity: 4_096)
    #endif

    /// Whether latency tracing is enabled for this process.
    public static let isEnabled: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["CMUX_LATENCY_TRACE"] == "1"
            || UserDefaults.standard.bool(forKey: "cmux.debug.latency-trace")
        #else
        false
        #endif
    }()

    /// Emits one machine-parseable latency stamp to the mobile file sink.
    ///
    /// - Parameters:
    ///   - stage: Stable stage token.
    ///   - fields: Integer or short-token fields, without terminal content.
    @inline(__always)
    public static func stamp(
        _ stage: StaticString,
        _ fields: @autoclosure () -> String = ""
    ) {
        #if DEBUG
        guard isEnabled else { return }
        write(stage, uptimeMicroseconds: nowUptimeMicroseconds(), fields: fields())
        #endif
    }

    /// Captures the monotonic clock only when tracing is enabled.
    @inline(__always)
    public static func captureTime() -> UInt64? {
        #if DEBUG
        guard isEnabled else { return nil }
        return nowUptimeMicroseconds()
        #else
        return nil
        #endif
    }

    /// Emits a stamp at a previously captured time when tracing is enabled.
    ///
    /// - Parameters:
    ///   - stage: Stable stage token.
    ///   - uptimeMicroseconds: Previously captured monotonic uptime.
    ///   - fields: Integer or short-token fields, without terminal content.
    @inline(__always)
    public static func stamp(
        _ stage: StaticString,
        at uptimeMicroseconds: UInt64,
        _ fields: @autoclosure () -> String = ""
    ) {
        #if DEBUG
        guard isEnabled else { return }
        write(stage, uptimeMicroseconds: uptimeMicroseconds, fields: fields())
        #endif
    }

    /// Returns elapsed microseconds from a captured trace start.
    ///
    /// - Parameter start: Previously captured monotonic uptime.
    /// - Returns: Elapsed monotonic microseconds.
    @inline(__always)
    public static func elapsedMicroseconds(since start: UInt64) -> UInt64 {
        #if DEBUG
        nowUptimeMicroseconds() &- start
        #else
        0
        #endif
    }

    #if DEBUG
    /// Emits a completion stamp for an optionally captured trace start.
    ///
    /// - Parameters:
    ///   - stage: Stable completion-stage token.
    ///   - start: Captured start, or `nil` when tracing was disabled.
    ///   - fields: Builds fields from the elapsed microseconds.
    @inline(__always)
    public static func stampElapsed(
        _ stage: StaticString,
        since start: UInt64?,
        _ fields: (_ elapsedMicroseconds: UInt64) -> String
    ) {
        guard isEnabled else { return }
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
        writer.enqueue("LAT \(stage) t=\(uptimeMicroseconds)\(suffix)")
    }
    #endif
}
