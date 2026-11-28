public import Sentry
import Foundation

/// One ended screen share viewer session's numbers (goal screen-share-fast): connect to the first
/// frame on glass, and the session's display-to-glass ("total") and decoded-to-glass ("present")
/// p50/p95, read from the Rust core's `cmux.rd-session-report/1` JSON.
///
/// Sent as one info event per session, all in one Sentry issue (fingerprint
/// `screen_share_session`), numbers only: nothing names a person, a Mac, a host or what was shared.
/// Each number is both `extra` and a tag, as ``StallSummaryReport`` does: the fleet's Discover read
/// selects tags (Discover cannot select `extra`).
/// The fleet's present-time board reads these and falls back to the nightly probe without them.
public nonisolated struct ScreenShareSessionEvent: Sendable, Equatable {
    public let firstFrameMs: Double?
    public let totalP50Ms: Double?
    public let totalP95Ms: Double?
    public let totalCount: Int
    public let presentP50Ms: Double?
    public let presentP95Ms: Double?
    public let presentCount: Int
    public let framesPresented: Int
    public let presentingSeconds: Double

    /// Reads a session report; nil when it is not one.
    public init?(reportJSON: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(reportJSON.utf8)) as? [String: Any],
              object["schema"] as? String == "cmux.rd-session-report/1" else { return nil }
        func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
        let total = object["total"] as? [String: Any]
        let present = object["present"] as? [String: Any]
        firstFrameMs = number(object["first_frame_ms"])
        totalP50Ms = number(total?["p50_ms"])
        totalP95Ms = number(total?["p95_ms"])
        totalCount = Int(number(total?["n"]) ?? 0)
        presentP50Ms = number(present?["p50_ms"])
        presentP95Ms = number(present?["p95_ms"])
        presentCount = Int(number(present?["n"]) ?? 0)
        framesPresented = Int(number(object["frames_presented"]) ?? 0)
        presentingSeconds = number(object["presenting_s"]) ?? 0
    }

    /// The numbers as Sentry `extra` (absent percentiles left out).
    public var extra: [String: Any] {
        var extra: [String: Any] = ["frames_presented": framesPresented, "presenting_s": presentingSeconds,
                                    "total_n": totalCount, "present_n": presentCount]
        let optional: [(String, Double?)] = [("first_frame_ms", firstFrameMs), ("total_p50_ms", totalP50Ms),
                                             ("total_p95_ms", totalP95Ms), ("present_p50_ms", presentP50Ms),
                                             ("present_p95_ms", presentP95Ms)]
        for (key, value) in optional { if let value { extra[key] = value } }
        return extra
    }

    /// The Sentry event: info level, one issue for every session.
    public func event() -> Event {
        let event = Event(level: .info)
        event.platform = "cocoa"
        event.message = SentryMessage(formatted: "screen share session")
        event.fingerprint = ["screen_share_session"]
        var tags = ["screen_share": "session"]
        for (key, value) in extra { tags[key] = "\(value)" }
        event.tags = tags
        event.extra = extra
        return event
    }
}

extension CrashReporter {
    /// Sends one ended viewer session's report (`cmux.rd-session-report/1` JSON). Does nothing when
    /// crash reporting is off (anonymous telemetry off) or the text is not a session report.
    public nonisolated func reportScreenShareSession(json: String) {
        guard isStarted, let session = ScreenShareSessionEvent(reportJSON: json) else { return }
        SentrySDK.capture(event: session.event())
    }
}
