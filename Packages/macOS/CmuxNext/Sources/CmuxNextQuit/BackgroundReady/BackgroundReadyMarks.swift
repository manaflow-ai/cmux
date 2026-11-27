import CmuxNextControl
import Foundation

/// The background ready copy's marks, written to the launch marks' sink (`CMUX_NEXT_LAUNCH_MARKS_PATH`, the
/// launch harness's FIFO) as `<name> <ms since process start>` each time, not once per process as a launch
/// mark: every show writes its `reopen.*` marks again.
nonisolated enum BackgroundReadyMarks {
    /// `reopen.<name>`: `requested`, `window_shown`, `first_frame_committed`, `window_usable`, `agent_pane.painted`.
    static func reopen(_ name: String, at date: Date = Date()) {
        each("reopen.\(name)", at: date)
    }

    static func each(_ name: String, at date: Date = Date()) {
        LaunchMarkSink.shared.write(name: name, ms: date.timeIntervalSince(LaunchTimesRecorder.processStart) * 1_000)
    }
}
