public import CmuxNextInputCore
#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
import Darwin
public import WebKit
#endif

/// Takes over an input latency slot at the commit that would close it, to close it later from a better presented
/// time (``WebPageInputTiming`` for WebKit pages). ``InputLatencyTracker`` asks its deferral, after stamping
/// `mainCommit` and before stamping `presented`; a slot it takes is finished through ``InputSlotFinishing``.
@MainActor
public protocol InputSlotCloseDeferring: AnyObject {
    /// Whether this takes `token`'s slot over. False leaves it to close now with the commit's estimate.
    ///
    /// - Parameters:
    ///   - token: The open slot.
    ///   - kind: What the person did.
    ///   - target: The view it landed in.
    ///   - generatedNanos: The slot's `generated` stage (`CLOCK_UPTIME_RAW` ns).
    func takeOver(_ token: InputLatencyToken, kind: InputEventKind, target: InputTarget, generatedNanos: UInt64) -> Bool
}

/// Closes a slot an ``InputSlotCloseDeferring`` took over, the way the tracker closes its own: the closed-slot ring,
/// the `input.latency` signpost and the batch sink. ``InputLatencyTracker`` is the app's.
@MainActor
public protocol InputSlotFinishing: AnyObject {
    /// The open-slot table the slots live in; stages are stamped here before ``finish(_:)``.
    var table: InputLatencySlotTable { get }

    /// Closes `token`'s slot now, with the stages it has.
    func finish(_ token: InputLatencyToken)
}

#if DEBUG || CMUX_BENCH_HOOKS

/// The presented stage of an input that lands in a WebKit page, from the page's own frame (presentation source
/// ``CmuxNextInputCore/InputPresentationSource/pageEstimated``). DEV and bench builds only: no other build compiles it,
/// so no shipped page runs its script.
///
/// AppKit's commit says nothing about the page: WebKit draws in its web content process, frames later. Chrome closes
/// an input's Event Timing entry at the presentation of the next paint after its handlers
/// (third_party/blink/renderer/core/timing/window_performance.cc, `ReportEventTimings`). A page here does the same
/// as far as WebKit lets it: a capture listener asks for the next animation frame, and a task after that frame runs
/// once the frame rendered (as `PagePaintProbe`). The page posts four numbers, never what was typed or where:
/// `[kind, timeOrigin, event.timeStamp, rendered]` (kind 0 key down, 1 mouse down, 2 mouse up, 3 wheel).
/// `PerformanceEventTiming` is not used: its duration is rounded to 8 ms and entries under 16 ms are not reported
/// (performance_event_timing.cc), too coarse below one 120 Hz frame.
///
/// - Page clock to uptime: each report is a sample of `received - rendered`, at least the real offset; the
///   smallest sample per document (`timeOrigin`) is used, the minimum filter of a two-clock sync.
/// - Matching: the open slot of the same kind whose `generated` is nearest the page's event time, within 100 ms.
///   Reports come in event order, so older slots of that kind left before the match never get one: they close with
///   `presented` skipped (readers drop them) and count as missed. A report with no slot counts as unmatched and is
///   dropped. A slot waits at most 1 s.
/// - The matched slot gets `contentSubmitted` = the page's render time, `presented` = the presentation estimate of a
///   commit ending then (the window's next vsync plus one render-server frame), and source `pageEstimated`.
///
/// ```swift
/// let pageTiming = WebPageInputTiming(slots: tracker, presentation: presentationClock)
/// tracker.closeDeferral = pageTiming
/// pageTiming.install(into: webViewConfiguration.userContentController)
/// ```
public final class WebPageInputTiming: InputSlotCloseDeferring {
    /// The message handler and content world name: an isolated world, so page scripts cannot post reports.
    public static let handlerName = "cmuxInputTiming"
    /// Slots waiting for their page report at most.
    static let pendingCapacity = 32
    /// How long a slot waits for its report.
    static let maxWaitNanos: UInt64 = 1_000_000_000
    /// How far a report's event time may be from its slot's `generated` stage.
    static let matchToleranceNanos: UInt64 = 100_000_000
    /// Documents whose clock offset is kept.
    static let clockCapacity = 8

    /// Reports and slots since launch (debug.input).
    public struct Counts: Sendable, Equatable {
        /// Slots closed from a page report.
        public var matched: UInt64 = 0
        /// Reports with no waiting slot of their kind near their event time.
        public var unmatched: UInt64 = 0
        /// Slots closed with `presented` skipped: no report within 1 s, or a newer slot of their kind was matched.
        public var missed: UInt64 = 0
        /// Slots not taken because ``pendingCapacity`` slots were waiting (they closed at their commit).
        public var refused: UInt64 = 0
        /// Messages that were not four numbers of a known kind.
        public var malformed: UInt64 = 0

        public init() {}
    }

    /// One slot waiting for its page report.
    private struct Waiting {
        let token: InputLatencyToken
        let kind: UInt8
        let generated: UInt64
    }

    /// One document's page clock: uptime ns = page ns + offset.
    private struct PageClock {
        let origin: Double
        var offset: Int64
        var used: UInt64
    }

    /// One page report.
    struct Report {
        let kind: UInt8
        let origin: Double
        let eventMs: Double
        let renderedMs: Double

        /// The report in a message body, or nil when it is not `[kind, timeOrigin, timeStamp, rendered]`.
        init?(_ body: Any) {
            guard let values = body as? [Any], values.count == 4 else { return nil }
            var numbers: [Double] = []
            numbers.reserveCapacity(4)
            for value in values {
                guard let number = value as? NSNumber else { return nil }
                let double = number.doubleValue
                guard double.isFinite, double >= 0 else { return nil }
                numbers.append(double)
            }
            guard numbers[0] < 4, numbers[0] == numbers[0].rounded() else { return nil }
            kind = UInt8(numbers[0])
            origin = numbers[1]
            eventMs = numbers[2]
            renderedMs = numbers[3]
        }
    }

    private let slots: any InputSlotFinishing
    private let presentation: any InputPresentationEstimating
    private let now: () -> UInt64
    private var waiting: [Waiting] = []
    private var clocks: [PageClock] = []

    /// Reports and slots since launch.
    public private(set) var counts = Counts()

    /// A timing on `CLOCK_UPTIME_RAW` (`NSEvent.timestamp`'s clock).
    ///
    /// - Parameters:
    ///   - slots: Closes the slots this takes over (the app's tracker).
    ///   - presentation: The presented estimate of a commit (the app's `PresentationClock`).
    public convenience init(slots: any InputSlotFinishing, presentation: any InputPresentationEstimating) {
        self.init(slots: slots, presentation: presentation, now: { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) })
    }

    /// - Parameters:
    ///   - slots: Closes the slots this takes over.
    ///   - presentation: The presented estimate of a commit.
    ///   - now: `CLOCK_UPTIME_RAW` nanoseconds now.
    public init(slots: any InputSlotFinishing, presentation: any InputPresentationEstimating,
                now: @escaping () -> UInt64) {
        self.slots = slots
        self.presentation = presentation
        self.now = now
        waiting.reserveCapacity(Self.pendingCapacity)
        clocks.reserveCapacity(Self.clockCapacity)
    }

    /// Slots waiting for a report (tests).
    var waitingCount: Int { waiting.count }

    /// Adds the page script, in its own content world, and its message handler to `controller` (one per tab).
    /// The controller keeps the handler and the handler keeps this.
    public func install(into controller: WKUserContentController) {
        let world = WKContentWorld.world(name: Self.handlerName)
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: world))
        controller.add(Receiver(timing: self), contentWorld: world, name: Self.handlerName)
    }

    // MARK: InputSlotCloseDeferring

    public func takeOver(_ token: InputLatencyToken, kind: InputEventKind, target: InputTarget,
                         generatedNanos: UInt64) -> Bool {
        guard target == .webkitPage, let code = Self.pageKind(kind) else { return false }
        expire(at: now())
        guard waiting.count < Self.pendingCapacity else {
            counts.refused &+= 1
            return false
        }
        waiting.append(Waiting(token: token, kind: code, generated: generatedNanos))
        return true
    }

    // MARK: Reports

    /// Takes one page message body, received now, from a page in `window`.
    public func receive(_ body: Any, in window: NSWindow?) {
        receive(body, in: window, receivedNanos: now())
    }

    /// Takes one page message body received at `receivedNanos` (`CLOCK_UPTIME_RAW`).
    func receive(_ body: Any, in window: NSWindow?, receivedNanos: UInt64) {
        expire(at: receivedNanos)
        guard let report = Report(body) else {
            counts.malformed &+= 1
            return
        }
        let offset = clockOffset(for: report, receivedNanos: receivedNanos)
        let eventNanos = Self.uptime(pageMs: report.eventMs, offset: offset, ceiling: receivedNanos)
        guard let index = nearestWaiting(kind: report.kind, eventNanos: eventNanos) else {
            counts.unmatched &+= 1
            return
        }
        let matched = waiting[index]
        // Reports come in event order: a slot of this kind older than the match will get none.
        var kept = 0
        for position in waiting.indices {
            let entry = waiting[position]
            if position == index { continue }
            if position < index, entry.kind == matched.kind {
                counts.missed &+= 1
                slots.finish(entry.token)
            } else {
                waiting[kept] = entry
                kept += 1
            }
        }
        waiting.removeLast(waiting.count - kept)

        let rendered = max(Self.uptime(pageMs: report.renderedMs, offset: offset, ceiling: receivedNanos),
                           matched.generated)
        let table = slots.table
        table.mark(matched.token, .contentSubmitted, at: rendered)
        table.mark(matched.token, .presented, at: presentation.presentedNanos(commitEndNanos: rendered, in: window))
        table.setPresentationSource(matched.token, .pageEstimated)
        counts.matched &+= 1
        slots.finish(matched.token)
    }

    /// Closes every slot that waited longer than ``maxWaitNanos``, with `presented` skipped.
    private func expire(at nowNanos: UInt64) {
        guard let oldest = waiting.first, nowNanos > oldest.generated &+ Self.maxWaitNanos else { return }
        var kept = 0
        for position in waiting.indices {
            let entry = waiting[position]
            if nowNanos > entry.generated &+ Self.maxWaitNanos {
                counts.missed &+= 1
                slots.finish(entry.token)
            } else {
                waiting[kept] = entry
                kept += 1
            }
        }
        waiting.removeLast(waiting.count - kept)
    }

    /// The waiting slot of `kind` whose `generated` stage is nearest `eventNanos`, within ``matchToleranceNanos``.
    private func nearestWaiting(kind: UInt8, eventNanos: UInt64) -> Int? {
        var best: (index: Int, distance: UInt64)?
        for (index, entry) in waiting.enumerated() where entry.kind == kind {
            let distance = entry.generated > eventNanos ? entry.generated - eventNanos : eventNanos - entry.generated
            if distance <= Self.matchToleranceNanos, distance < best?.distance ?? .max { best = (index, distance) }
        }
        return best?.index
    }

    /// The report's document offset (uptime ns minus page ns), lowered by this report's sample: the report was
    /// posted at `rendered` and arrived at `receivedNanos`, so the sample is the real offset plus the delivery time.
    private func clockOffset(for report: Report, receivedNanos: UInt64) -> Int64 {
        let sample = Int64(clamping: receivedNanos) &- Self.pageNanos(report.renderedMs)
        if let index = clocks.firstIndex(where: { $0.origin == report.origin }) {
            clocks[index].offset = min(clocks[index].offset, sample)
            clocks[index].used = receivedNanos
            return clocks[index].offset
        }
        let clock = PageClock(origin: report.origin, offset: sample, used: receivedNanos)
        if clocks.count < Self.clockCapacity {
            clocks.append(clock)
        } else if let stalest = clocks.indices.min(by: { clocks[$0].used < clocks[$1].used }) {
            clocks[stalest] = clock
        }
        return sample
    }

    // MARK: Values

    /// The page's kind code for a slot kind, or nil for kinds the page does not report.
    static func pageKind(_ kind: InputEventKind) -> UInt8? {
        switch kind {
        case .keyPress: 0
        case .mousePress: 1
        case .mouseRelease: 2
        case .scrollBegin, .scrollFirstUpdate, .scrollUpdate, .scrollMomentum: 3
        case .keyRelease, .flags, .pointerMove, .drag, .scrollEnd, .magnify: nil
        }
    }

    /// Page milliseconds (finite, not negative) as nanoseconds, clamped to `Int64.max`.
    private static func pageNanos(_ milliseconds: Double) -> Int64 {
        let nanos = (milliseconds * 1_000_000).rounded()
        return nanos < 9.2e18 ? Int64(nanos) : .max
    }

    /// A page time on the uptime clock, at least 1 and at most `ceiling` (the page cannot report the future).
    private static func uptime(pageMs: Double, offset: Int64, ceiling: UInt64) -> UInt64 {
        let nanos = pageNanos(pageMs).addingReportingOverflow(offset)
        guard !nanos.overflow, nanos.partialValue > 0 else { return 1 }
        return min(UInt64(nanos.partialValue), ceiling)
    }

    /// The page script: numbers only, posted after the frame that follows each trusted key down, mouse down, mouse
    /// up and wheel event.
    static let script = """
    (() => {
      const handlers = window.webkit && window.webkit.messageHandlers;
      const handler = handlers && handlers.\(handlerName);
      if (!handler) return;
      const origin = performance.timeOrigin;
      const report = (kind, start) => requestAnimationFrame(() => setTimeout(() => {
        handler.postMessage([kind, origin, start, performance.now()]);
      }, 0));
      const track = (type, kind) => addEventListener(type, (event) => {
        if (event.isTrusted) report(kind, event.timeStamp);
      }, { capture: true, passive: true });
      track("keydown", 0);
      track("mousedown", 1);
      track("mouseup", 2);
      track("wheel", 3);
    })();
    """

    /// The page's message handler; keeps its ``WebPageInputTiming``.
    private final class Receiver: NSObject, WKScriptMessageHandler {
        private let timing: WebPageInputTiming

        init(timing: WebPageInputTiming) {
            self.timing = timing
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame else { return }
            timing.receive(message.body, in: message.webView?.window)
        }
    }
}

#endif
