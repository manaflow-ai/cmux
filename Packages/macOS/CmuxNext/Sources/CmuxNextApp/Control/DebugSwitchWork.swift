import CmuxNextDesign
import CmuxNextSettings

/// Main-thread follow-up work (a window record save, a trail encode) that runs while a recorded
/// switch waits for the commit that shows it: work that can push the switch's frame late. Each
/// switch timer counts it per kind as `work_before_commit` (`debug.pane_focus`,
/// `debug.workspace_switch`, `debug.tab_switch`, `debug.input_commit`; reset by each one's `start`).
@MainActor
enum DebugSwitchWork {
    /// The switch timers that count follow-up work besides `debug.pane_focus` (which keeps its own).
    enum Timer: CaseIterable {
        case workspaceSwitch, tabSwitch, input

        var timer: SwitchFrameTimer {
            switch self {
            case .workspaceSwitch: DebugWorkspaceSwitch.timer
            case .tabSwitch: DebugTabSwitch.timer
            case .input: DebugInputCommit.timer
            }
        }
    }

    private static var counts: [Timer: [String: Int]] = [:]

    /// Main-thread work of `kind` runs now.
    static func note(_ kind: String) {
        DebugPaneFocus.noteMainWork(kind)
        for which in Timer.allCases where which.timer.isRecording && which.timer.awaitsCommit {
            counts[which, default: [:]][kind, default: 0] += 1
        }
    }

    /// `which`'s socket reply (`SwitchFrameTimer.handle`, its rows under `key`) with its `work_before_commit`;
    /// `start` resets the counts.
    static func handle(_ params: [String: JSONValue], _ which: Timer, key: String) -> JSONValue {
        if params["action"]?.stringValue == "start" { counts[which] = [:] }
        guard case .object(var object) = which.timer.handle(params, key: key) else { return .null }
        object["work_before_commit"] = .object((counts[which] ?? [:]).mapValues { .number(Double($0)) })
        return .object(object)
    }
}
