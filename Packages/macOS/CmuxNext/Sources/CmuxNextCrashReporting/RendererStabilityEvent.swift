import Foundation
public import Sentry

/// The crash-reporting event of one rate-limited renderer stability report: a WebKit content
/// process that ended under a page, or a Chromium page that showed "Page unresponsive" and ended. Every field is a
/// closed-set name or a number (the reporter's `RendererStability.Report`); the event names no page, URL, title or host.
///
/// Warning level, no stack: the renderer is another process, and the app's own stack says nothing about why it ended.
/// Grouped by kind, engine and surface (the fingerprint), so a crash loop of one surface is one issue with a count.
public nonisolated struct RendererStabilityEvent: Sendable, Equatable {
    /// `content_ended` or `unresponsive`.
    public let kind: String
    /// `webkit` or `chromium`.
    public let engine: String
    /// `browser_tab`, `page` or `warmup`.
    public let surface: String
    /// Events of this kind, engine and surface since the last report, this one included.
    public let count: Int
    /// An unresponsive span's length in ms; nil for a content end.
    public let unresponsiveMilliseconds: Int64?
    /// How an unresponsive span ended (`responsive`, `process_ended`, `navigated`, `closed`); nil for a content end.
    public let ending: String?

    public init(kind: String, engine: String, surface: String, count: Int, unresponsiveMilliseconds: Int64? = nil,
                ending: String? = nil) {
        self.kind = kind
        self.engine = engine
        self.surface = surface
        self.count = count
        self.unresponsiveMilliseconds = unresponsiveMilliseconds
        self.ending = ending
    }

    /// The Sentry event: a message, the `stability.*` tags, the count (and the span) in `extra`, and a fingerprint
    /// of the three names. A field that is not a name (``name(_:)``) goes as `other`, so no caller can put a page's
    /// URL or title in the event.
    public func event() -> Event {
        let (kind, engine, surface) = (Self.name(self.kind), Self.name(self.engine), Self.name(self.surface))
        let event = Event(level: .warning)
        event.platform = "cocoa"
        event.message = SentryMessage(formatted: "renderer stability: \(engine) \(kind) on \(surface)")
        var tags = ["stability.kind": kind, "stability.engine": engine, "stability.surface": surface]
        if let ending { tags["stability.ending"] = Self.name(ending) }
        event.tags = tags
        var extra: [String: Any] = ["stability_count": count]
        if let unresponsiveMilliseconds { extra["unresponsive_ms"] = unresponsiveMilliseconds }
        event.extra = extra
        event.fingerprint = ["renderer_stability", kind, engine, surface]
        return event
    }

    /// `value` when it is a closed-set name (1 to 32 lowercase ASCII letters and underscores), else `other`.
    static func name(_ value: String) -> String {
        let isName = (1 ... 32).contains(value.utf8.count) && value.utf8.allSatisfy { (0x61 ... 0x7A).contains($0) || $0 == 0x5F }
        return isName ? value : "other"
    }
}

/// Sends ``RendererStabilityEvent``s through a ``CrashReporter`` on its own utility lane, never on the caller's
/// (main) thread. With crash reporting off this launch (consent, managed policy, a DEV build without
/// `CMUX_NEXT_DEV_SENTRY=1`, tests) nothing is enqueued, and the lane checks again before it sends.
///
/// ```swift
/// let sentry = RendererStabilityReporter(reporter: crashReporting.reporter)
/// sentry.send(RendererStabilityEvent(kind: "content_ended", engine: "webkit", surface: "page", count: 1))
/// ```
public final class RendererStabilityReporter: Sendable {
    /// Runs one block off the caller's thread, in order.
    public typealias Lane = @Sendable (@escaping @Sendable () -> Void) -> Void
    /// Sends one built event.
    public typealias Capture = @Sendable (Event) -> Void

    private let sends: @Sendable () -> Bool
    private let lane: Lane
    private let capture: Capture

    /// Sends through `reporter` on a utility queue of its own, while `reporter` runs.
    public convenience init(reporter: CrashReporter) {
        let queue = DispatchQueue(label: "com.cmuxterm.app.next.renderer-stability", qos: .utility)
        self.init(sends: { reporter.isStarted }, lane: { queue.async(execute: $0) },
                  capture: { reporter.reportRendererStability($0) })
    }

    /// Test seam: whether it sends, the lane and the capture.
    public init(sends: @escaping @Sendable () -> Bool, lane: @escaping Lane, capture: @escaping Capture) {
        self.sends = sends
        self.lane = lane
        self.capture = capture
    }

    /// Builds and sends `report`'s event on the lane.
    public func send(_ report: RendererStabilityEvent) {
        guard sends() else { return }
        let capture = capture
        lane { capture(report.event()) }
    }
}

extension CrashReporter {
    /// Sends a renderer stability event. Call on a crash-reporting lane; does nothing when crash reporting is off.
    public nonisolated func reportRendererStability(_ event: Event) {
        guard isStarted else { return }
        SentrySDK.capture(event: event)
    }
}
