import Foundation
import OSLog

/// Push-latency probe (optimum-ledger row 16, send -> on-device receive). A sender with the probe on
/// (`APNS_SENT_AT_PROBE=1` on the web route, `PUSH_SENT_AT_PROBE=1` on the Workers) puts the wall clock where
/// it hands the push to APNs beside `aps`, as `cmuxSentAtMs`. The service extension calls `record` first thing in `didReceive`; the difference is one os_log line
/// and one signpost event (`dev.cmux.mobile`, category `push-latency`), readable from a device's unified log
/// (`log collect`, `xcrun devicectl`). Without the stamp nothing is logged.
///
/// The two clocks are the server's and the phone's, so the number carries their offset (NTP keeps both
/// within tens of ms) and APNs's own queueing; it is the "send to receive" the ledger names, not a
/// one-clock interval.
public enum PushLatencyProbe {
    private static let log = Logger(subsystem: "dev.cmux.mobile", category: "push-latency")
    private static let signposter = OSSignposter(subsystem: "dev.cmux.mobile", category: "push-latency")

    /// Milliseconds from the sender's stamp to `now`, or nil when the push carries none (or an absurd one).
    public static func latencyMs(userInfo: [AnyHashable: Any], now: Date = Date()) -> Double? {
        guard let sent = (userInfo["cmuxSentAtMs"] as? NSNumber)?.doubleValue, sent > 1_000_000_000_000 else { return nil }
        return now.timeIntervalSince1970 * 1000 - sent
    }

    /// Logs the latency of a delivered push, if it carries a stamp. Returns it (for tests).
    @discardableResult
    public static func record(userInfo: [AnyHashable: Any], now: Date = Date()) -> Double? {
        guard let ms = latencyMs(userInfo: userInfo, now: now) else { return nil }
        log.notice("push-latency ms=\(Int(ms.rounded()), privacy: .public)")
        signposter.emitEvent("push-latency", "ms=\(Int(ms.rounded()), privacy: .public)")
        return ms
    }
}
