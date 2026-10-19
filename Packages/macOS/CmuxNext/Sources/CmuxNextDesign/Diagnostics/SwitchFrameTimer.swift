public import AppKit
import CmuxNextWakeups
import QuartzCore

/// Debug timing of a switch to the screen (`debug.tab_switch`, cx-8w027.25): per switch, `apply_ms`
/// from the intent to the shown selection, `commit_ms` to the Core Animation commit that carries it
/// (after AppKit's layout and display, ``CommitProbe``) and `commit_end_ms` to its end (an upper
/// bound: the encode and the window-server transaction), `late_vsyncs` / `late_end_vsyncs`: the frames
/// each missed. The update cycle commits once per frame, so a switch commits after the next vsync at
/// the earliest (0: the first frame it could). The vsync grid is a display-link tick after the
/// commit; a stalled (synthesized) tick waits for the next. Records between ``start()`` and ``stop()``.
@MainActor
public final class SwitchFrameTimer {
    private struct Pending { var start: CFTimeInterval, applied: CFTimeInterval, commit: (CFTimeInterval, CFTimeInterval)? = nil }

    public private(set) var isRecording = false
    /// One row per timed switch (milliseconds and frame counts).
    public private(set) var samples: [[String: Double]] = []
    private var started: [ObjectIdentifier: CFTimeInterval] = [:]
    private var pending: [Pending] = []
    /// One probe per window that showed a switch while recording (a switch outside a window is not timed).
    private var probes: [ObjectIdentifier: CommitProbe] = [:]
    private let capacity = 1_024
    private var client: FrameClient?

    public init(owner: String) {
        client = FrameClient(owner: owner, isAnimation: false, on: .app) { [weak self] tick in self?.frame(tick) ?? false }
    }

    public func start() {
        (started, pending, samples, isRecording) = ([:], [], [], true)
    }

    public func stop() {
        (started, pending, isRecording) = ([:], [], false)
        for probe in probes.values { probe.remove() }
        probes = [:]
        client?.deactivate()
    }

    /// A switch intent for `key`; the latest one counts (an intent that never shows leaves no sample).
    public func began(_ key: ObjectIdentifier) {
        started[key] = CACurrentMediaTime()
    }

    /// `key` shows its new selection in `window`: the transaction open now carries it to the screen.
    public func shown(_ key: ObjectIdentifier, in window: NSWindow?) {
        guard isRecording, let start = started.removeValue(forKey: key), let window, let host = window.contentView?.layer else { return }
        pending.append(Pending(start: start, applied: CACurrentMediaTime()))
        let probe = probes[ObjectIdentifier(window)] ?? CommitProbe { [weak self] in self?.committed(at: ($0, $1)) }
        probes[ObjectIdentifier(window)] = probe
        probe.mark(in: host)
        client?.activate()
    }

    /// The commit that displayed a probe ran: it carried every switch shown before it.
    private func committed(at time: (CFTimeInterval, CFTimeInterval)) {
        for index in pending.indices where pending[index].commit == nil && pending[index].applied <= time.0 { pending[index].commit = time }
    }

    private func frame(_ tick: FrameTick) -> Bool {
        // `tick.timestamp` is a vsync (not on a stalled tick): each instant maps to the first vsync at or after it.
        guard let refresh = tick.refreshInterval else { return true }
        func vsync(after time: CFTimeInterval) -> CFTimeInterval {
            tick.timestamp + ((time - tick.timestamp) / refresh).rounded(.up) * refresh
        }
        pending.removeAll { switched in
            guard let times = switched.commit, times.1 <= tick.timestamp else { return false }
            let late = { (time: CFTimeInterval) in max(0, ((vsync(after: time) - vsync(after: switched.applied)) / refresh).rounded() - 1) }
            if samples.count < capacity {
                samples.append(["apply_ms": (switched.applied - switched.start) * 1_000, "commit_ms": (times.0 - switched.start) * 1_000,
                                "commit_end_ms": (times.1 - switched.start) * 1_000, "late_vsyncs": late(times.0),
                                "late_end_vsyncs": late(times.1), "refresh_ms": refresh * 1_000])
            }
            return true
        }
        return !pending.isEmpty
    }
}
