public import AppKit
import CmuxNextWakeups
import Darwin
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
/// Every row also has `cpu_ms`: main-thread CPU time from the intent to the end of its commit (the
/// intent, the observation turns, AppKit's layout and display). With a ``settleWindow`` (space switch:
/// the slide that follows), a row waits that long after its commit and adds `settle_missed_frames`
/// (vsyncs the main thread's display link skipped in the window: a frame not drawn on time) and
/// `settle_max_frame_ms` (its longest frame interval).
@MainActor
public final class SwitchFrameTimer {
    private struct Started {
        var start: CFTimeInterval
        var input: CFTimeInterval?
        var stages: [String: CFTimeInterval] = [:]
        var kind = "unknown"
        var cpu = SwitchFrameTimer.threadCPU()
    }
    private struct Pending {
        var started: Started, applied: CFTimeInterval, commit: (CFTimeInterval, CFTimeInterval)? = nil, extra: [String: Double] = [:]
        var cpuEnd: Double?
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
    /// Recent display-link ticks (time, interval since the previous one), for the settle window.
    private var ticks: [(time: CFTimeInterval, interval: Double, refresh: Double)] = []

    /// How long a row waits after its commit to count the frames that follow (0: none).
    public var settleWindow: CFTimeInterval = 0

    public init(owner: String) {
        client = FrameClient(owner: owner, isAnimation: false, on: .app) { [weak self] tick in self?.frame(tick) ?? false }
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
    public func began(_ key: AnyHashable, at time: CFTimeInterval = CACurrentMediaTime(), inputTimestamp: TimeInterval? = nil) {
        // Only an event from this switch's own input (not one left over from a launch or a menu).
        let input = inputTimestamp.flatMap { time - $0 >= 0 && time - $0 < 1 ? $0 : nil }
        started[key] = Started(start: time, input: input)
    }

    /// Whether `key` began and has not shown yet.
    public func isWaiting(_ key: AnyHashable) -> Bool { started[key] != nil }

    /// Drops the intent of `key` that will not show (no sample).
    public func forget(_ key: AnyHashable) { started[key] = nil }

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
    /// `extra` joins the sample's columns.
    public func shown(_ key: AnyHashable, in window: NSWindow?, extra: [String: Double] = [:]) {
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

    /// The commit that displayed a probe ran: it carried every switch shown before it.
    private func committed(at time: (CFTimeInterval, CFTimeInterval)) {
        let cpu = Self.threadCPU()
        for index in pending.indices where pending[index].commit == nil && pending[index].applied <= time.0 {
            pending[index].commit = time
            pending[index].cpuEnd = cpu
        }
    }

    /// The calling thread's CPU time, seconds (the timer runs on the main thread).
    nonisolated static func threadCPU() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    private func frame(_ tick: FrameTick) -> Bool {
        // `tick.timestamp` is a vsync (not on a stalled tick): each instant maps to the first vsync at or after it.
        guard let refresh = tick.refreshInterval else { return true }
        if settleWindow > 0 {
            ticks.append((tick.timestamp, tick.rawElapsed, refresh))
            let horizon = tick.timestamp - settleWindow - 2
            if let first = ticks.firstIndex(where: { $0.time >= horizon }), first > 0 { ticks.removeFirst(first) }
        }
        func vsync(after time: CFTimeInterval) -> CFTimeInterval {
            tick.timestamp + ((time - tick.timestamp) / refresh).rounded(.up) * refresh
        }
        pending.removeAll { switched in
            guard let times = switched.commit, times.1 <= tick.timestamp else { return false }
            if settleWindow > 0, tick.timestamp < times.1 + settleWindow { return false }
            let late = { (time: CFTimeInterval) in max(0, ((vsync(after: time) - vsync(after: switched.applied)) / refresh).rounded() - 1) }
            let start = switched.started.start
            if samples.count < capacity {
                var row = ["apply_ms": (switched.applied - start) * 1_000, "commit_ms": (times.0 - start) * 1_000,
                           "commit_end_ms": (times.1 - start) * 1_000, "late_vsyncs": late(times.0),
                           "late_end_vsyncs": late(times.1), "refresh_ms": refresh * 1_000]
                if let input = switched.started.input { row["input_ms"] = (start - input) * 1_000 }
                if let cpuEnd = switched.cpuEnd { row["cpu_ms"] = (cpuEnd - switched.started.cpu) * 1_000 }
                if settleWindow > 0 {
                    // Frames from the intent to the end of the settle window: each tick's interval past one refresh is frames skipped.
                    // The first one counts only its part after the intent (the link may have been idle before).
                    let window = ticks.filter { $0.time > start && $0.time <= times.1 + settleWindow }
                        .map { (interval: min($0.interval, $0.time - start), refresh: $0.refresh) }
                    row["settle_missed_frames"] = window.reduce(0) { $0 + max(0, ($1.interval / $1.refresh).rounded() - 1) }
                    row["settle_max_frame_ms"] = (window.map(\.interval).max() ?? 0) * 1_000
                }
                for (stage, time) in switched.started.stages { row[stage + "_ms"] = (time - start) * 1_000 }
                samples.append(row.merging(switched.extra) { own, _ in own })
                kinds.append(switched.started.kind)
            }
            return true
        }
        return !pending.isEmpty
    }
}
