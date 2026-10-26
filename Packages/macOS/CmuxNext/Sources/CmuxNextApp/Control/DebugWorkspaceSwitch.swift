import AppKit
import CmuxNextDesign
import CmuxNextSignposts

/// `debug.workspace_switch`: the app's own time per workspace switch (`SwitchFrameTimer`), from the
/// intent (`WindowManager.show(workspaceID:in:)`, every entry: a sidebar click, Cmd-1…9, next or
/// previous workspace, the palette, a socket action) to the shown content (`WindowController.show`)
/// to the Core Animation commit that carries it. `input_ms` is the triggering event's age (a click's
/// release, a key), so a switch that waits on its event shows there. Stages: `park`, `sidebar`,
/// `root`, `theme`, `did_show` (since the intent). Lawrence 2026-10-21: "changing workspaces is laggy".
///
/// Every switch is also the `switch.workspace` trace interval in every build, recording or not (perf-hot
/// `workspace-switch`): an `os_signpost` interval and a ring async pair from the intent (begin `arg0`: the
/// input age in microseconds, all ones without an input event) to the `CommitBoundary` after the turn that
/// shows it. A recorded row starts at that interval's begin, and its `signpost_ms` is the interval.
@MainActor
enum DebugWorkspaceSwitch {
    static let timer = SwitchFrameTimer(owner: "debug.workspace_switch", signpost: SignpostName.switchWorkspace)

    /// The window whose switch begins now (a switch is keyed by its window's controller).
    static func began(_ owner: AnyObject) {
        let event = NSApp.currentEvent
        let input = event.flatMap { [.leftMouseDown, .leftMouseUp, .keyDown].contains($0.type) ? $0.timestamp : nil }
        timer.began(ObjectIdentifier(owner), inputTimestamp: input)
    }

    static func mark(_ owner: AnyObject, _ stage: StaticString) {
        if timer.isRecording { timer.mark(ObjectIdentifier(owner), "\(stage)") }
    }

    static func kind(_ owner: AnyObject, _ kind: String) {
        if timer.isRecording { timer.setKind(ObjectIdentifier(owner), kind) }
    }

    /// `owner` shows the new workspace in `window`: the switch ends at this turn's commit.
    static func shown(_ owner: AnyObject, in window: NSWindow?) {
        timer.shown(ObjectIdentifier(owner), in: window)
    }

    /// `owner` already shows the workspace asked for: the switch changes nothing and leaves no sample.
    static func unchanged(_ owner: AnyObject) {
        timer.forget(ObjectIdentifier(owner))
    }
}
