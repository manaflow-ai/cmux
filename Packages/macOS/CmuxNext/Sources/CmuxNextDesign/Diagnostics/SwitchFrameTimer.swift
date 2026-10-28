public import AppKit
public import CmuxNextSignposts
public import CmuxNextTrace
public import CmuxNextWakeups
import QuartzCore

/// Debug timing of a switch to the screen (`debug.tab_switch`, cx-8w027.25): per switch, `apply_ms`
/// from the intent to the shown selection, `commit_ms` to the Core Animation commit that carries it
/// (after AppKit's layout and display, ``CommitProbe``) and `commit_end_ms` to its end (an upper
/// bound: the encode and the window-server transaction), `late_vsyncs` / `late_end_vsyncs`: the frames
/// each missed. The update cycle commits once per frame, so a switch commits after the next vsync at
/// the earliest (0: the first frame it could). The vsync grid is a display-link tick after the
/// commit; a stalled (synthesized) tick waits for the next. Records between ``start()`` and ``stop()``.
///
/// Stages (tab-switch-fast): `input_ms` is the OS event's age when the intent began (a click or key;
/// absent for a socket action), each ``mark(_:_:)`` adds `<stage>_ms` since the intent, and ``kinds``
/// names the content each row showed (`cold`: a first visit, whose content shows a frame later).
/// ``confirms`` holds, per shown switch, when the daemon stored the selection
/// (``confirmed(requestedAt:)``, asynchronous: the switch never waits for it).
///
/// With a `signpost` name, every switch is also a ``Signposter`` interval in every build, recording or
/// not (the `os_signpost` interval and its ring async pair, AB/AE): begun at the intent with the input
/// age in microseconds as `arg0` (all ones without an input event), ended by the ``CommitBoundary``
/// after the intent's turn: the switch shows in that turn (I6) or never. A switch that did not show
/// by then, a second intent or ``forget(_:)`` ends the open one as missed (`commit=missed`), so
/// readers and MetricKit drop it, and a later show without its own intent writes nothing. A recorded row starts at the interval's begin
/// time and its `signpost_ms` ends at the boundary, so the Debug rows and the trace read the same
/// timestamps. Chrome times a tab switch the same way: one async trace event from the input to the
/// presented frame, closed by `ContentToVisibleTimeReporter`
/// (content/browser/renderer_host/visible_time_request_trigger.h).
@MainActor
public final class SwitchFrameTimer {
    private struct Started {
        var start: CFTimeInterval
        var input: CFTimeInterval?
        var stages: [String: CFTimeInterval] = [:]
        var kind = "unknown"
        /// The serial of the switch's open trace interval, when the timer has a `signpost` name.
        var traced: UInt64?
    }
    private struct Pending {
        var started: Started, applied: CFTimeInterval, commit: (CFTimeInterval, CFTimeInterval)? = nil, extra: [String: Double] = [:]
        /// When the ``CommitBoundary`` ended the switch's trace interval, and whether it missed the commit.
        var boundary: (time: CFTimeInterval, missed: Bool)?
    }
    /// A switch's open trace interval: begun at its intent, ended once (at its turn's boundary, superseded or forgotten).
    private struct OpenInterval {
        var serial: UInt64
        var interval: SignpostInterval
        /// The switch showed in its intent's turn, so the boundary ends it with the commit's outcome.
        var shown = false
    }

    public private(set) var isRecording = false
    /// One row per timed switch (milliseconds and frame counts).
    public private(set) var samples: [[String: Double]] = []
    /// The content kind each row of ``samples`` showed (`terminal`, `chromium`, `webkit`, `page`, ...).
    public private(set) var kinds: [String] = []
    /// Daemon confirm latency of each switch that was shown (ms), in order.
    public private(set) var confirms: [Double] = []
    private var started: [AnyHashable: Started] = [:]
    private var pending: [Pending] = []
    /// Switches shown and not yet confirmed by the daemon: (intent time, shown time).
    private var unconfirmed: [(start: CFTimeInterval, shown: CFTimeInterval)] = []
    /// One probe per window that showed a switch while recording (a switch outside a window is not timed).
    private var probes: [ObjectIdentifier: CommitProbe] = [:]
    private let capacity = 1_024
    private var client: FrameClient?
    /// The trace interval each switch is, in every build (nil: no trace interval).
    private let signpost: SignpostName?
    private let signposter: Signposter?
    /// The trace interval of each switch that began and has not ended.
    private var open: [AnyHashable: OpenInterval] = [:]
    private var lastSerial: UInt64 = 0

    /// - Parameters:
    ///   - owner: The frame client's owner name (the debug socket method).
    ///   - signpost: The trace interval each switch also is, recording or not (a `switch` name).
    ///   - trace: The runtime the interval's ring pair goes to (tests pass their own).
    ///   - frames: The scheduler whose ticks place commits on the vsync grid (tests pass a fake link's).
    public init(owner: String, signpost: SignpostName? = nil, trace: TraceRuntime = .shared, frames: FrameScheduler = .app) {
        self.signpost = signpost
        signposter = signpost.map { Signposter(category: $0.traceCategory, trace: trace) }
        // Only a recording (a debug socket method) places commits on the vsync grid; the trace interval needs no frames.
        #if DEBUG || CMUX_BENCH_HOOKS
        client = FrameClient(owner: owner, isAnimation: false, on: frames) { [weak self] tick in self?.frame(tick) ?? false }
        #endif
    }

    /// Runs at each `start()`, for an owner's own per-recording state.
    public var onStart: (@MainActor () -> Void)?

    public func start() {
        (started, pending, samples, kinds, confirms, unconfirmed, isRecording) = ([:], [], [], [], [], [], true)
        onStart?()
    }

    public func stop() {
        (started, pending, unconfirmed, isRecording) = ([:], [], [], false)
        for probe in probes.values { probe.remove() }
        probes = [:]
        client?.deactivate()
    }

    /// A switch intent for `key` (at `time`, default now); the latest one counts (an intent that never shows leaves no sample).
    /// `inputTimestamp` is the triggering event's `NSEvent.timestamp` (same clock as `CACurrentMediaTime`).
    /// With a `signpost` name it begins the switch's trace interval, recording or not, ends the one `key`
    /// left open as superseded, and a recorded row starts at the interval's begin time instead of `time`.
    public func began(_ key: AnyHashable, at time: CFTimeInterval = CACurrentMediaTime(), inputTimestamp: TimeInterval? = nil) {
        // Only an event from this switch's own input (not one left over from a launch or a menu).
        let input = inputTimestamp.flatMap { time - $0 >= 0 && time - $0 < 1 ? $0 : nil }
        let traced = beginInterval(key, inputAge: input.map { time - $0 })
        guard isRecording else { return }
        let start = traced.map { Double($0.interval.beginUptimeNanos) / 1_000_000_000 } ?? time
        started[key] = Started(start: start, input: input, traced: traced?.serial)
    }

    /// Whether `key` began and has not shown yet.
    public func isWaiting(_ key: AnyHashable) -> Bool { started[key] != nil }

    /// Whether `key`'s trace interval began and has neither shown nor ended, recording or not: a later
    /// caller of the same intent keeps it instead of superseding it.
    public func awaitsShow(_ key: AnyHashable) -> Bool { open[key].map { !$0.shown } ?? false }

    /// Whether a switch was shown and its Core Animation commit has not run yet.
    public var awaitsCommit: Bool { pending.contains { $0.commit == nil } }

    /// Drops the intent of `key` that will not show (no sample; its trace interval ends as superseded).
    public func forget(_ key: AnyHashable) {
        started[key] = nil
        if let interval = open.removeValue(forKey: key) { endSuperseded(interval) }
    }

    /// The switch of `key` reached `stage` (`focus`, `strip`, `content`, `view`, ...).
    public func mark(_ key: AnyHashable, _ stage: String) {
        guard isRecording, started[key] != nil else { return }
        started[key]?.stages[stage] = CACurrentMediaTime()
    }

    /// The content kind the switch of `key` shows.
    public func setKind(_ key: AnyHashable, _ kind: String) {
        guard isRecording, started[key] != nil else { return }
        started[key]?.kind = kind
    }

    /// `key` shows its new selection in `window`: the transaction open now carries it to the screen.
    /// `extra` joins the sample's columns. A trace interval begun in this turn ends at its ``CommitBoundary``.
    public func shown(_ key: AnyHashable, in window: NSWindow?, extra: [String: Double] = [:]) {
        open[key]?.shown = true
        guard isRecording, let switched = started.removeValue(forKey: key), let window, let host = window.contentView?.layer else { return }
        let applied = CACurrentMediaTime()
        pending.append(Pending(started: switched, applied: applied, extra: extra))
        if unconfirmed.count < capacity { unconfirmed.append((switched.start, applied)) }
        let probe = probes[ObjectIdentifier(window)] ?? CommitProbe { [weak self] in self?.committed(at: ($0, $1)) }
        probes[ObjectIdentifier(window)] = probe
        probe.mark(in: host)
        client?.activate()
    }

    /// The daemon stored the selections shown before `requested` (a window record write landed).
    public func confirmed(requestedAt requested: CFTimeInterval) {
        guard isRecording else { return }
        let now = CACurrentMediaTime()
        // A write carries the selections shown before it read the window state.
        unconfirmed.removeAll { switched in
            guard switched.shown <= requested else { return false }
            if confirms.count < capacity { confirms.append((now - switched.start) * 1_000) }
            return true
        }
    }

    /// Begins `key`'s trace interval, superseding the one it left open.
    private func beginInterval(_ key: AnyHashable, inputAge: CFTimeInterval?) -> OpenInterval? {
        guard let signpost, let signposter else { return nil }
        if let superseded = open.removeValue(forKey: key) { endSuperseded(superseded) }
        lastSerial &+= 1
        let serial = lastSerial
        let ageMicros = inputAge.map { UInt64(($0 * 1_000_000).rounded()) } ?? .max
        let opened = OpenInterval(serial: serial, interval: signposter.begin(signpost, "", arg0: ageMicros))
        open[key] = opened
        // The switch swaps its content in its intent's turn (I6), so that turn's boundary ends it either way.
        // Strong: the one-shot boundary must end the interval.
        CommitBoundary().after { outcome in self.boundary(key, serial, outcome) }
        return opened
    }

    /// Ends an interval before its boundary (it never showed, or a second intent in its turn replaced it):
    /// `commit=missed`, so readers and MetricKit drop it. A recorded row it showed reads the miss now.
    private func endSuperseded(_ opened: OpenInterval) {
        guard let signpost, let signposter else { return }
        let time = CACurrentMediaTime()
        signposter.end(signpost, opened.interval, .missed)
        guard let index = pending.firstIndex(where: { $0.started.traced == opened.serial }) else { return }
        pending[index].boundary = (time, true)
    }

    /// The ``CommitBoundary`` after the intent's turn ends the switch's trace interval, unless a second intent
    /// or ``forget(_:)`` already did: with the commit's outcome when it showed in that turn (a recorded row
    /// reads the same time), else as missed with no row, so a later show of `key` never ends it.
    private func boundary(_ key: AnyHashable, _ serial: UInt64, _ outcome: CommitBoundary.Outcome) {
        guard let opened = open[key], opened.serial == serial else { return }
        open[key] = nil
        guard opened.shown else {
            if started[key]?.traced == serial { started[key] = nil }
            return endSuperseded(opened)
        }
        guard let signpost, let signposter else { return }
        let time = CACurrentMediaTime()
        signposter.end(signpost, opened.interval, outcome)
        guard let index = pending.firstIndex(where: { $0.started.traced == serial }) else { return }
        pending[index].boundary = (time, outcome == .missed)
    }

    /// The commit that displayed a probe ran: it carried every switch shown before it.
    private func committed(at time: (CFTimeInterval, CFTimeInterval)) {
        for index in pending.indices where pending[index].commit == nil && pending[index].applied <= time.0 { pending[index].commit = time }
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    private func frame(_ tick: FrameTick) -> Bool {
        // `tick.timestamp` is a vsync (not on a stalled tick): each instant maps to the first vsync at or after it.
        guard let refresh = tick.refreshInterval else { return true }
        func vsync(after time: CFTimeInterval) -> CFTimeInterval {
            tick.timestamp + ((time - tick.timestamp) / refresh).rounded(.up) * refresh
        }
        pending.removeAll { switched in
            guard let times = switched.commit, times.1 <= tick.timestamp else { return false }
            // A switch with a trace interval waits for its boundary, so its row carries `signpost_ms`.
            if switched.started.traced != nil, switched.boundary == nil { return false }
            let late = { (time: CFTimeInterval) in max(0, ((vsync(after: time) - vsync(after: switched.applied)) / refresh).rounded() - 1) }
            let start = switched.started.start
            if samples.count < capacity {
                var row = ["apply_ms": (switched.applied - start) * 1_000, "commit_ms": (times.0 - start) * 1_000,
                           "commit_end_ms": (times.1 - start) * 1_000, "late_vsyncs": late(times.0),
                           "late_end_vsyncs": late(times.1), "refresh_ms": refresh * 1_000]
                if let input = switched.started.input { row["input_ms"] = (start - input) * 1_000 }
                if let boundary = switched.boundary {
                    row["signpost_ms"] = (boundary.time - start) * 1_000
                    if boundary.missed { row["signpost_missed"] = 1 }
                }
                for (stage, time) in switched.started.stages { row[stage + "_ms"] = (time - start) * 1_000 }
                samples.append(row.merging(switched.extra) { own, _ in own })
                kinds.append(switched.started.kind)
            }
            return true
        }
        return !pending.isEmpty
    }
    #endif
}
