#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import AppKit
import Darwin

/// Host mode's input route (feature `chromiumHostInputRing`; plans/cmux-next/chrome-parity/p01-process.md
/// 3.1, tasks 041, 042 and 092): the hosted page views' keys, clicks, pointer moves and wheel
/// ticks go into the attached host's input ring, each stamped with the input seq and control seq
/// the remote shim gives it, and the host's acks pace each page's moves and wheel ticks
/// (``ChromiumHostPageView/pacesInput``). As Chrome's `RenderWidgetHostNSViewHost` pipe carries a
/// page's input from its `RenderWidgetHostViewCocoa` to the browser process and
/// `MouseWheelEventQueue` sends the next wheel event on the ack
/// (components/input/mouse_wheel_event_queue.cc).
///
/// One per attached host, made by ``CEFHostStart`` with that host's ring: when the host ends,
/// ``hostEnded()`` takes every page off it (no sink, no pacing), and nothing in flight is
/// waited for. Focus does not go on the ring: a hosted page's focus is an ordered control op
/// (``CEFTab/applyFocus(_:browser:)``). Main actor: the ring's one writer is the thread that
/// receives `NSEvent`s.
final class ChromiumHostInputRoute {
    /// The next ring frame's input seq and control seq (`cmux_remote_shim_order_input`); nil when
    /// no host is attached, and then nothing is written.
    typealias Order = @MainActor () -> (seq: UInt32, ctlSeq: UInt32)?

    /// One page view on the route, and the browser its input goes to now.
    private struct Page {
        weak var view: ChromiumHostPageView?
        let browser: @MainActor () -> Int32?
    }

    /// Counts for `debug.chromium_host` (`input_route`).
    struct Stats: Equatable {
        var written: UInt64 = 0
        /// Frames not written: no host attached, no browser shown, or a ring that refused or dropped them.
        var unwritten: UInt64 = 0
        var acks: UInt64 = 0
        /// Acks for a browser no page view on the route sent to.
        var strayAcks: UInt64 = 0
    }

    /// The first wheel tick of each gesture (scroll phase may-begin or began): microseconds from
    /// its event's time to its ring write, the newest ``firstWheelSampleLimit`` (the acceptance's
    /// < 0.5 ms, chromium-host-bench.py `route` rows).
    private(set) var firstWheelSendMicros: [Double] = []
    static let firstWheelSampleLimit = 512

    private let ring: ChromiumHostInputRing
    private let order: Order
    private var pages: [ObjectIdentifier: Page] = [:]
    /// The page view each browser's input came from, for its acks; set when a write goes to a browser.
    private var viewOfBrowser: [Int32: ObjectIdentifier] = [:]
    private(set) var stats = Stats()

    init(ring: ChromiumHostInputRing, order: @escaping Order) {
        self.ring = ring
        self.order = order
    }

    /// `view`'s input goes into the ring, to the browser `browser()` names at each event (the pane's
    /// shown tab), paced by the host's acks; the host reports unhandled chords back (it sends keys
    /// with `SendHostKeyEvent`).
    func attach(_ view: ChromiumHostPageView, browser: @escaping @MainActor () -> Int32?) {
        let id = ObjectIdentifier(view)
        pages = pages.filter { $0.value.view != nil }  // panes that closed since
        pages[id] = Page(view: view, browser: browser)
        view.sink = { [weak self] frame in self?.write(frame, from: id) }
        view.pacesInput = true
        view.hostReportsUnhandledKeys = true
    }

    /// `view` leaves the route: its frames go nowhere and nothing it sent is waited for.
    func detach(_ view: ChromiumHostPageView) {
        let id = ObjectIdentifier(view)
        guard pages.removeValue(forKey: id) != nil else { return }
        viewOfBrowser = viewOfBrowser.filter { $0.value != id }
        Self.release(view)
    }

    /// The host this route's ring belongs to ended: every page leaves it.
    func hostEnded() {
        for page in pages.values {
            if let view = page.view { Self.release(view) }
        }
        pages.removeAll()
        viewOfBrowser.removeAll()
    }

    /// The host dispatched `browser`'s move (kind 3) or wheel tick (kind 4): that page view sends
    /// its next waiting one. Main thread, in the host's dispatch order.
    func acked(browser: Int32, kind: Int32, seq: UInt32) {
        stats.acks += 1
        let paced: ChromiumHostInputPacer.Paced
        switch UInt32(bitPattern: kind) {
        case ChromiumHostFrame.Kind.mouse.rawValue: paced = .move
        case ChromiumHostFrame.Kind.wheel.rawValue: paced = .wheel
        default: return
        }
        guard let id = viewOfBrowser[browser], let view = pages[id]?.view else {
            stats.strayAcks += 1
            return
        }
        view.inputAcked(paced, seq: seq)
    }

    /// For `debug.chromium_host`: the route's counts, the ring's, and each page's pacer.
    var report: [String: Any] {
        let ringStats = ring.stats
        var out: [String: Any] = [
            "written": Int(clamping: stats.written), "unwritten": Int(clamping: stats.unwritten),
            "acks": Int(clamping: stats.acks), "stray_acks": Int(clamping: stats.strayAcks),
            "ring_written": Int(clamping: ringStats.written), "ring_doorbells": Int(clamping: ringStats.doorbells),
            "ring_spilled": Int(clamping: ringStats.spilled), "ring_coalesced": Int(clamping: ringStats.coalesced),
            "ring_dropped": Int(clamping: ringStats.dropped), "ring_backlog": ring.backlogCount,
            "first_wheel_send_us": firstWheelSendMicros,
        ]
        out["pages"] = pages.values.compactMap { page -> [String: Any]? in
            guard let view = page.view, let pacer = view.inputPacer else { return nil }
            let paced = pacer.stats
            return ["browser": Int(page.browser() ?? 0), "moves_in_flight": pacer.movesInFlight,
                    "wheels_in_flight": pacer.wheelsInFlight, "waiting": pacer.waitingCount,
                    "max_moves_in_flight": paced.maxMovesInFlight, "max_wheels_in_flight": paced.maxWheelsInFlight,
                    "sent": Int(clamping: paced.sent), "coalesced": Int(clamping: paced.coalesced),
                    "flushed_ahead": Int(clamping: paced.flushedAhead), "dropped": Int(clamping: paced.dropped),
                    "unsent": Int(clamping: paced.unsent), "acks": Int(clamping: paced.acks),
                    "unexpected_acks": Int(clamping: paced.unexpectedAcks)]
        }
        return out
    }

    /// The page view's sink: one frame into the ring, for the browser its pane shows now. Nil when
    /// nothing was written (no host, no browser, a frame the ring refused or dropped), so the
    /// view's pacer waits for no ack of it.
    private func write(_ frame: ChromiumHostFrame, from id: ObjectIdentifier) -> ChromiumHostInputReceipt? { // perf-hot: 1us cef-host-input-ring (every key, click, move and wheel of a hosted page)
        guard frame.kind != .focus, let browser = pages[id]?.browser(), let ordered = order() else {
            stats.unwritten += 1
            return nil
        }
        switch ring.write(frame, browser: browser, seq: ordered.seq, ctlSeq: ordered.ctlSeq) {
        case .written, .spilled:
            stats.written += 1
            if viewOfBrowser[browser] != id { viewOfBrowser[browser] = id }
            if let wheel = frame.wheelFields, Self.startsGesture(wheel), frame.t0 > 0 { recordFirstWheel(sinceEvent: frame.t0) }
            return ChromiumHostInputReceipt(browser: browser, seq: ordered.seq)
        case .refused, .dropped, .broken:
            stats.unwritten += 1
            return nil
        }
    }

    /// `eventTime`: the tick's event time, CLOCK_UPTIME_RAW nanoseconds (``ChromiumHostPageView/nanoseconds(_:)``).
    private func recordFirstWheel(sinceEvent eventTime: UInt64) {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard now >= eventTime else { return }
        if firstWheelSendMicros.count == Self.firstWheelSampleLimit { firstWheelSendMicros.removeFirst() }
        firstWheelSendMicros.append(Double(now - eventTime) / 1_000)
    }

    /// A gesture's first wheel tick: scroll phase may-begin or began (NSEvent.Phase bits, p04-input-063's wire).
    private static func startsGesture(_ wheel: ChromiumHostFrame.Wheel) -> Bool {
        !NSEvent.Phase(rawValue: wheel.phase).isDisjoint(with: [.mayBegin, .began])
    }

    private static func release(_ view: ChromiumHostPageView) {
        view.sink = nil
        view.pacesInput = false
        view.hostReportsUnhandledKeys = false
    }

    /// C entry for the host's input acks (``CEFRemoteShim/setInputAck(context:ack:)``): runs on
    /// the main thread (remote_shim_runtime.h `cmux_remote_input_ack_fn`) with the route as its
    /// context, which ``CEFHostStart`` keeps alive while it is set.
    static let ackCallback: CEFRemoteShim.InputAckFn = { context, browser, kind, seq in
        // SAFETY: a non-NULL context is the route CEFHostStart set, unretained; CEFHostStart keeps it in
        // `inputRoute` and clears the ack (setInputAck(context: nil)) before it lets the route go.
        guard let route = unsafe context.map({ unsafe Unmanaged<ChromiumHostInputRoute>.fromOpaque($0).takeUnretainedValue() }) else { return }
        MainActor.assumeIsolated { // main-proof: cmux_remote_input_ack_fn runs on the main thread (remote_shim_runtime.h)
            route.acked(browser: browser, kind: kind, seq: seq)
        }
    }
}

extension CEFEngine {
    /// `debug.chromium_host`'s `input_route`: the host input route's counts and each page's pacer;
    /// nil without a route (in process, the feature off, or a host that passed no ring).
    public var hostInputReport: [String: Any]? { CEFRuntime.shared.hostStart?.inputRoute?.report }
}
#endif
