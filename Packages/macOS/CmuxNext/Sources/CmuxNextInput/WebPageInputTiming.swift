#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextInputCore
public import Foundation
public import WebKit

/// A WebKit page's presented stage, in DEV and bench builds (p04-input-099). WebKit draws a page's response to an
/// input in a frame of its own web process, after the app's commit, and tells the app nothing about it, so a
/// ``CmuxNextInputCore/InputTarget/webkitPage`` slot has no presented time of its own.
///
/// A user script in its own content world (a page can neither call the handler nor remove the listeners) listens, in
/// the capture phase and passive, for the trusted inputs a slot is opened for (``EventType``). At the first one of a
/// frame it asks for an animation frame; in that callback it posts a task, which runs after the frame's rendering
/// update: that time is the page's next paint after its handlers, the end WebKit's Event Timing gives an event's
/// `duration` (Blink waits further, for that frame's presentation feedback,
/// third_party/blink/renderer/core/timing/window_performance.cc; WebKit gives a page none). So the stage is when the
/// page's frame left its web process, before the render server showed it: the page's own estimate, not the glass.
/// The Event Timing entries themselves are not used: an observer gets only events of at least its 16 ms floor
/// (`durationThreshold`, third_party/blink/renderer/core/timing/performance_observer.cc), so the fast inputs this
/// stage measures would never be reported.
///
/// The script posts numbers only: the document's time origin, its clock now, and per input the event type, the
/// event's `timeStamp` and the paint time, all in page milliseconds. ``WebPageClock`` maps them to
/// `CLOCK_UPTIME_RAW`, and ``InputLatencyTracker/pagePresented(_:eventNanos:at:)`` closes the slot whose event time
/// is nearest, with source ``CmuxNextInputCore/InputPresentationSource/pageEstimated``. A report no slot takes is
/// counted in ``unmatchedEvents`` and dropped; a body that is not the script's is counted in ``malformedReports``.
///
/// Main frame only: an input in a subframe's document gets no report, and its slot closes at its deadline with no
/// presented time, as before. Wheel events are not reported: WebKit scrolls in the UI process, so a DOM wheel
/// event's frame is not the frame that shows the scroll.
///
/// ```swift
/// webKitEngine.pageInputTiming = WebPageInputTiming(tracker: services.inputLatency.tracker)
/// // each new tab: engine.pageInputTiming?.install(into: configuration.userContentController)
/// ```
public final class WebPageInputTiming {
    /// The inputs a page reports, as the script codes them.
    nonisolated public enum EventType: Int, Sendable, CaseIterable {
        case keyDown = 0
        case pointerDown = 1
        case pointerUp = 2

        /// The slot kind this event's input opened (p04-input-005: one slot per key down, button down and up).
        public var kind: InputEventKind {
            switch self {
            case .keyDown: .keyPress
            case .pointerDown: .mousePress
            case .pointerUp: .mouseRelease
            }
        }

        /// The DOM event the script listens for.
        public var domType: String {
            switch self {
            case .keyDown: "keydown"
            case .pointerDown: "pointerdown"
            case .pointerUp: "pointerup"
            }
        }
    }

    /// The script's message handler name.
    public static let channel = "cmuxInputTiming"
    /// The content world the script and its handler live in.
    public static let worldName = "cmux-input-timing"
    /// How far a report's event time may be from its slot's `generated` stage. The page clock is coarsened to 1 ms
    /// and its offset to uptime is known to within one message's delivery, so a report is a few ms off at most.
    public static let matchToleranceNanos: UInt64 = 50_000_000

    private weak var tracker: InputLatencyTracker?
    private let now: @Sendable () -> UInt64

    /// Reported inputs that closed a slot with the page's paint time.
    public private(set) var matchedEvents: UInt64 = 0
    /// Reported inputs that no open page slot took (not tracked, closed at its deadline first, or out of tolerance).
    public private(set) var unmatchedEvents: UInt64 = 0
    /// Message bodies that were not the script's report.
    public private(set) var malformedReports: UInt64 = 0

    /// - Parameters:
    ///   - tracker: The app's tracker, held weakly.
    ///   - now: `CLOCK_UPTIME_RAW` nanoseconds now, when a report arrives.
    public init(tracker: InputLatencyTracker, now: @escaping @Sendable () -> UInt64 = InputLatencyTracker.uptimeNanos) {
        self.tracker = tracker
        self.now = now
    }

    /// Adds the script and its handler to one tab's controller. The controller keeps the handler, which keeps its
    /// page's clock and this object.
    public func install(into controller: WKUserContentController) {
        let world = WKContentWorld.world(name: Self.worldName)
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: world))
        controller.add(WebPageInputTimingReceiver(timing: self), contentWorld: world, name: Self.channel)
    }

    /// Applies one report the script posted, read with the page's clock.
    ///
    /// - Parameters:
    ///   - body: The message body.
    ///   - clock: The posting page's clock; a new document resets it.
    public func receive(_ body: Any, clock: inout WebPageClock) {
        let received = now()
        guard let report = Report(body) else {
            malformedReports &+= 1
            return
        }
        clock.observe(origin: report.origin, pageNowMillis: report.pageNow, receivedAt: received)
        for event in report.events {
            guard let eventNanos = clock.uptime(event.eventMillis), let painted = clock.uptime(event.paintedMillis),
                  let tracker, tracker.pagePresented(event.type, eventNanos: eventNanos, at: min(painted, received))
            else {
                unmatchedEvents &+= 1
                continue
            }
            matchedEvents &+= 1
        }
    }

    /// The user script: the listeners and the after-paint report.
    public static let script: String = {
        let types = EventType.allCases.map { "\($0.domType): \($0.rawValue)" }.joined(separator: ", ")
        return """
        (() => {
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(WebPageInputTiming.channel);
          if (!handler) return;
          const types = { \(types) };
          let queued = [];
          const afterPaint = new MessageChannel();
          afterPaint.port1.onmessage = (message) => {
            const painted = performance.now();
            const batch = message.data, events = [];
            for (let i = 0; i < batch.length; i += 2) events.push(batch[i], batch[i + 1], painted);
            handler.postMessage({ o: performance.timeOrigin, n: performance.now(), e: events });
          };
          const frame = () => {
            afterPaint.port2.postMessage(queued);
            queued = [];
          };
          const record = (event) => {
            if (!event.isTrusted) return;
            if (queued.length === 0) requestAnimationFrame(frame);
            queued.push(types[event.type], event.timeStamp);
          };
          for (const type of Object.keys(types)) window.addEventListener(type, record, { capture: true, passive: true });
        })();
        """
    }()

    /// One message of the script, checked: every field a finite number, the events in threes.
    struct Report {
        struct Event {
            let type: EventType
            let eventMillis: Double
            let paintedMillis: Double
        }

        let origin: Double
        let pageNow: Double
        let events: [Event]

        init?(_ body: Any) {
            guard let fields = body as? [String: Any], let origin = Self.number(fields["o"]),
                  let pageNow = Self.number(fields["n"]), let flat = fields["e"] as? [Any], flat.count % 3 == 0
            else { return nil }
            var events: [Event] = []
            events.reserveCapacity(flat.count / 3)
            for start in stride(from: 0, to: flat.count, by: 3) {
                guard let code = Self.number(flat[start]).flatMap({ Int(exactly: $0) }),
                      let type = EventType(rawValue: code), let eventMillis = Self.number(flat[start + 1]),
                      let paintedMillis = Self.number(flat[start + 2])
                else { return nil }
                events.append(Event(type: type, eventMillis: eventMillis, paintedMillis: paintedMillis))
            }
            (self.origin, self.pageNow, self.events) = (origin, pageNow, events)
        }

        private static func number(_ value: Any?) -> Double? {
            guard let value = (value as? NSNumber)?.doubleValue, value.isFinite else { return nil }
            return value
        }
    }
}

/// A page's clock (`performance.now()`, milliseconds since its document's time origin) mapped to `CLOCK_UPTIME_RAW`.
///
/// Each report carries the page's time when it posted; the report arrives later, so `received - posted` is the
/// offset plus that delivery's latency. The smallest such value seen is the best estimate (a one-way clock
/// sync, as NTP keeps its minimum-delay sample). A report from a new document (another time origin) starts over.
nonisolated public struct WebPageClock: Sendable, Equatable {
    /// The document's time origin the offset belongs to.
    public private(set) var origin: Double?
    /// Uptime nanoseconds at the page's time 0.
    public private(set) var offsetNanos: Int64?

    public init() {}

    /// Takes one report's post time.
    ///
    /// - Parameters:
    ///   - origin: The document's `performance.timeOrigin`.
    ///   - pageNowMillis: The page's `performance.now()` when it posted.
    ///   - received: `CLOCK_UPTIME_RAW` nanoseconds when the report arrived.
    public mutating func observe(origin: Double, pageNowMillis: Double, receivedAt received: UInt64) {
        guard let pageNow = Self.nanos(pageNowMillis), received <= UInt64(Int64.max) else { return }
        let offset = Int64(received) - pageNow
        if self.origin != origin || offsetNanos == nil {
            self.origin = origin
            offsetNanos = offset
        } else if let offsetNanos, offset < offsetNanos {
            self.offsetNanos = offset
        }
    }

    /// The uptime of page time `millis`, or nil before any report or when it maps before boot.
    public func uptime(_ millis: Double) -> UInt64? {
        guard let offsetNanos, let nanos = Self.nanos(millis) else { return nil }
        let (sum, overflow) = nanos.addingReportingOverflow(offsetNanos)
        return !overflow && sum > 0 ? UInt64(sum) : nil
    }

    private static func nanos(_ millis: Double) -> Int64? {
        let nanos = (millis * 1_000_000).rounded()
        return nanos.isFinite && nanos >= 0 && nanos < 9.0e18 ? Int64(nanos) : nil
    }
}

/// One tab's handler: its main frame's reports, read with its own clock.
final class WebPageInputTimingReceiver: NSObject, WKScriptMessageHandler {
    private let timing: WebPageInputTiming
    private var clock = WebPageClock()

    init(timing: WebPageInputTiming) { self.timing = timing }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        timing.receive(message.body, clock: &clock)
    }
}

extension InputLatencyTracker {
    /// Closes the open WebKit page slot of a reported input at `presentedNanos`, the page's paint after its handlers:
    /// source ``CmuxNextInputCore/InputPresentationSource/pageEstimated`` (``WebPageInputTiming``). The slot is the
    /// one of `type`'s kind whose `generated` time is nearest `eventNanos`, within
    /// ``WebPageInputTiming/matchToleranceNanos`` (the oldest on a tie). A slot still in its turn gets the time now
    /// and closes at the turn's commit; one past it closes at once. One whose deadline passed closes with no presented
    /// time, as a late `contentSubmitted` makes it.
    ///
    /// - Parameters:
    ///   - type: The reported DOM event.
    ///   - eventNanos: The event's time, mapped to `CLOCK_UPTIME_RAW` nanoseconds.
    ///   - presentedNanos: The paint after its handlers, mapped the same way.
    /// - Returns: Whether a slot took the time (false: nothing changed, or the slot closed with no presented time).
    @discardableResult
    public func pagePresented(_ type: WebPageInputTiming.EventType, eventNanos: UInt64, at presentedNanos: UInt64)
        -> Bool {
        guard eventNanos != 0 else { return false }
        var inTurn: (offset: Int, distance: UInt64)?
        for (offset, entry) in pending.enumerated() {
            guard let distance = pageDistance(entry.token, entry.target, entry.kind, type, eventNanos, presentedNanos),
                  distance < inTurn?.distance ?? .max else { continue }
            inTurn = (offset, distance)
        }
        var past: (offset: Int, distance: UInt64)?
        for (offset, entry) in waiting.enumerated() {
            guard let distance = pageDistance(entry.token, entry.target, entry.kind, type, eventNanos, presentedNanos),
                  distance < past?.distance ?? .max else { continue }
            past = (offset, distance)
        }
        if let past, past.distance <= inTurn?.distance ?? .max {
            let entry = waiting.remove(at: past.offset)
            let stamped = presentedNanos <= entry.deadline && stampPagePresented(entry.token, at: presentedNanos)
            close(entry.token, presented: nil)
            return stamped
        }
        guard let inTurn else { return false }
        return stampPagePresented(pending[inTurn.offset].token, at: presentedNanos)
    }

    /// How far a slot's `generated` time is from a reported event time, or nil when the slot cannot be the report's:
    /// not a WebKit page's, another kind, painted before its event, or outside the tolerance.
    private func pageDistance(_ token: InputLatencyToken, _ target: InputTarget, _ kind: InputEventKind,
                              _ type: WebPageInputTiming.EventType, _ eventNanos: UInt64,
                              _ presentedNanos: UInt64) -> UInt64? {
        guard target == .webkitPage, kind == type.kind, let generated = table.time(token, .generated),
              presentedNanos >= generated else { return nil }
        let distance = generated > eventNanos ? generated - eventNanos : eventNanos - generated
        return distance <= WebPageInputTiming.matchToleranceNanos ? distance : nil
    }

    private func stampPagePresented(_ token: InputLatencyToken, at nanos: UInt64) -> Bool {
        guard table.mark(token, .presented, at: nanos) else { return false }
        table.setPresentationSource(token, .pageEstimated)
        return true
    }
}
#endif
