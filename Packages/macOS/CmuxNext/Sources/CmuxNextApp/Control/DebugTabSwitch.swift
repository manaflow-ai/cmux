import CmuxNextControl
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextWakeups
import AppKit
import QuartzCore

/// `debug.tab_switch`: the app's own time per tab switch, apart from the socket reply (which waits
/// for the daemon's confirm): `apply_ms` from the intent (`PaneController.select`) to the shown
/// selection, `commit_ms` to the Core Animation commit that carries it (after AppKit's layout and
/// display, `CommitProbe`) and `commit_end_ms` to its end (the encode and the window-server
/// transaction), `late_vsyncs` / `late_end_vsyncs`: the frames each missed. The update cycle commits
/// once per frame, so a switch commits after the next vsync at the earliest (0: the first frame it
/// could). The vsync grid is a display-link tick after the commit (cx-8w027.25). Records between `start` and `stop`.
@MainActor
enum DebugTabSwitch {
    private struct Pending { var start: CFTimeInterval, applied: CFTimeInterval, commit: (CFTimeInterval, CFTimeInterval)? = nil }

    private(set) static var isRecording = false
    private static var started: [ObjectIdentifier: CFTimeInterval] = [:]
    private static var pending: [Pending] = []
    /// One probe per window that showed a switch while recording (a switch outside a window is not timed).
    private static var probes: [ObjectIdentifier: CommitProbe] = [:]
    private static var samples: [[String: JSONValue]] = []
    private static let capacity = 1_024
    private static let client = FrameClient(owner: "debug.tab_switch", isAnimation: false, on: .app) { tick in
        // `tick.timestamp` is a vsync (not on a synthesized, stalled tick): each instant maps to the first vsync at or after it.
        guard let refresh = tick.refreshInterval else { return true }
        func vsync(after time: CFTimeInterval) -> CFTimeInterval {
            tick.timestamp + ((time - tick.timestamp) / refresh).rounded(.up) * refresh
        }
        pending.removeAll { switched in
            guard let times = switched.commit, times.1 <= tick.timestamp else { return false }
            let (commit, end) = times
            let late = { (time: CFTimeInterval) in max(0, ((vsync(after: time) - vsync(after: switched.applied)) / refresh).rounded() - 1) }
            if samples.count < capacity {
                samples.append(["apply_ms": .number((switched.applied - switched.start) * 1_000),
                                "commit_ms": .number((commit - switched.start) * 1_000), "commit_end_ms": .number((end - switched.start) * 1_000),
                                "late_vsyncs": .number(late(commit)), "late_end_vsyncs": .number(late(end)), "refresh_ms": .number(refresh * 1_000)])
            }
            return true
        }
        return !pending.isEmpty
    }

    /// A switch intent for the pane `owner`; the latest one counts (an intent that never shows leaves no sample).
    static func began(_ owner: AnyObject) {
        started[ObjectIdentifier(owner)] = CACurrentMediaTime()
    }

    /// The pane `owner` shows its new selection in `window`: the transaction open now carries it to the screen.
    static func shown(_ owner: AnyObject, in window: NSWindow?) {
        guard isRecording, let start = started.removeValue(forKey: ObjectIdentifier(owner)), let window,
              let host = window.contentView?.layer else { return }
        pending.append(Pending(start: start, applied: CACurrentMediaTime()))
        let probe = probes[ObjectIdentifier(window)] ?? CommitProbe { committed(at: ($0, $1)) }
        probes[ObjectIdentifier(window)] = probe
        probe.mark(in: host)
        client.activate()
    }

    /// The commit that displayed a probe ended: it carried every switch shown before it.
    private static func committed(at time: (CFTimeInterval, CFTimeInterval)) {
        for index in pending.indices where pending[index].commit == nil && pending[index].applied <= time.0 { pending[index].commit = time }
    }

    static func handle(_ params: [String: JSONValue]) -> JSONValue {
        switch params["action"]?.stringValue ?? "read" {
        case "start":
            (started, pending, samples, isRecording) = ([:], [], [], true)
        case "stop":
            let report = self.report
            (started, pending, isRecording) = ([:], [], false)
            for probe in probes.values { probe.remove() }
            probes = [:]
            client.deactivate()
            return report
        default:
            break
        }
        return report
    }

    private static var report: JSONValue {
        ["recording": .bool(isRecording), "switches": .array(samples.map { .object($0) })]
    }
}

