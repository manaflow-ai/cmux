import CmuxNextControl
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextWakeups
import AppKit
import QuartzCore

/// `debug.tab_switch`: the app's own time per tab switch, apart from the socket reply (which waits
/// for the daemon's confirm): `apply_ms` from the intent (`PaneController.select`) to the shown
/// selection, `commit_ms` to the end of the Core Animation commit that carries it (`CommitProbe`: on
/// macOS 26 the update cycle commits once per frame from its own run loop source, not at the run
/// loop's idle, and macOS has no commit handler API), `vsync_ms` to the first vsync after it, and `late_vsyncs`, the frames the
/// commit missed (a switch commits after the next vsync at the earliest; 0: the first frame it could).
/// The vsync grid is a display-link tick after the commit (cx-8w027.25). Records between `start` and `stop`.
@MainActor
enum DebugTabSwitch {
    private struct Pending { var start: CFTimeInterval, applied: CFTimeInterval, commit: CFTimeInterval? = nil }

    private(set) static var isRecording = false
    private static var started: [ObjectIdentifier: CFTimeInterval] = [:]
    private static var pending: [Pending] = []
    /// One probe per window that showed a switch while recording.
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
            guard let commit = switched.commit, commit <= tick.timestamp else { return false }
            if samples.count < capacity {
                let frames = ((vsync(after: commit) - vsync(after: switched.applied)) / refresh).rounded()
                samples.append(["apply_ms": .number((switched.applied - switched.start) * 1_000),
                                "commit_ms": .number((commit - switched.start) * 1_000),
                                "vsync_ms": .number((vsync(after: commit) - switched.start) * 1_000),
                                "late_vsyncs": .number(max(0, frames - 1)), "refresh_ms": .number(refresh * 1_000)])
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
        guard isRecording, let start = started.removeValue(forKey: ObjectIdentifier(owner)) else { return }
        pending.append(Pending(start: start, applied: CACurrentMediaTime()))
        if let host = window?.contentView?.layer {
            let probe = probes[ObjectIdentifier(host)] ?? CommitProbe(host: host) { committed(at: $0) }
            probes[ObjectIdentifier(host)] = probe
            probe.mark()
        }
        client.activate()
    }

    /// The commit that displayed a probe ended: it carried every switch shown before it.
    private static func committed(at time: CFTimeInterval) {
        for index in pending.indices where pending[index].commit == nil && pending[index].applied <= time { pending[index].commit = time }
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

