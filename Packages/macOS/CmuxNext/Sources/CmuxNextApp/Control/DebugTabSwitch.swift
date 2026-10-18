import CmuxNextControl
import CmuxNextSettings
import CmuxNextWakeups
import QuartzCore

/// `debug.tab_switch`: the app's own time for each tab switch, apart from the
/// socket reply (which also waits for the daemon to confirm the selection):
/// `apply_ms` from the switch intent (`PaneController.select`) to the shown
/// selection (`applySelection` done), `frame_ms` to the first display frame
/// after it, the earliest frame that can show the new tab (cx-8w027.21,
/// scripts/cmux-next/perf-gate.py). Records only between `start` and `stop`.
@MainActor
enum DebugTabSwitch {
    private(set) static var isRecording = false
    private static var started: [ObjectIdentifier: CFTimeInterval] = [:]
    private static var applied: [(start: CFTimeInterval, applied: CFTimeInterval)] = []
    private static var samples: [(apply: Double, frame: Double)] = []
    private static let capacity = 1_024
    private static let client = FrameClient(owner: "debug.tab_switch", isAnimation: false, on: .app) { _ in
        let now = CACurrentMediaTime()
        for switched in applied where samples.count < capacity {
            samples.append(((switched.applied - switched.start) * 1_000, (now - switched.start) * 1_000))
        }
        applied.removeAll(keepingCapacity: true)
        return false
    }

    /// A switch intent for the pane `owner`; the latest one counts (an intent that never shows leaves no sample).
    static func began(_ owner: AnyObject) {
        started[ObjectIdentifier(owner)] = CACurrentMediaTime()
    }

    /// The pane `owner` shows its new selection: the next frame can draw it.
    static func shown(_ owner: AnyObject) {
        guard isRecording, let start = started.removeValue(forKey: ObjectIdentifier(owner)) else { return }
        applied.append((start, CACurrentMediaTime()))
        client.activate()
    }

    static func handle(_ params: [String: JSONValue]) -> JSONValue {
        switch params["action"]?.stringValue ?? "read" {
        case "start":
            (started, applied, samples, isRecording) = ([:], [], [], true)
        case "stop":
            let report = self.report
            (started, applied, isRecording) = ([:], [], false)
            client.deactivate()
            return report
        default:
            break
        }
        return report
    }

    private static var report: JSONValue {
        ["recording": .bool(isRecording),
         "apply_ms": .array(samples.map { .number($0.apply) }),
         "frame_ms": .array(samples.map { .number($0.frame) })]
    }
}
