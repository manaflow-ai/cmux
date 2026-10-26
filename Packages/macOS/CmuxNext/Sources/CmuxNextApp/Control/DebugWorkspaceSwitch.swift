import AppKit
import CmuxNextDesign
import CmuxNextFocusUI
import CmuxNextSignposts

/// `debug.workspace_switch`: the app's own time per workspace switch (`SwitchFrameTimer`), from the
/// intent (`WindowManager.show(workspaceID:in:)`, every entry: a sidebar click, Cmd-1…9, next or
/// previous workspace, the palette, a socket action) to the shown content (`WindowController.show`)
/// to the Core Animation commit that carries it. `input_ms` is the age of the key or click being
/// dispatched (``InputDispatchContext/inputTimestamp``, the action run's input), so a switch that waits
/// on its event shows there; a socket or CLI switch has none. Stages: `park`, `sidebar`,
/// `root`, `theme`, `did_show` (since the intent). Lawrence 2026-10-21: "changing workspaces is laggy".
///
/// Every switch is also the `switch.workspace` trace interval in every build, recording or not (perf-hot
/// `workspace-switch`): an `os_signpost` interval and a ring async pair from the intent (begin `arg0`: the
/// input age in microseconds, all ones without an input event) to the `CommitBoundary` after the intent's
/// turn. An intent that shows nothing in its turn (a top page, Home, a machine still connecting) ends there
/// as missed, so a later show by another path never closes it. A recorded row starts at that interval's begin, and its `signpost_ms` is the interval.
@MainActor
enum DebugWorkspaceSwitch {
    static let timer = SwitchFrameTimer(owner: "debug.workspace_switch", signpost: SignpostName.switchWorkspace)

    /// The window whose switch begins now (a switch is keyed by its window's controller).
    static func began(_ owner: WindowController) {
        timer.began(ObjectIdentifier(owner), inputTimestamp: owner.services.inputDispatch.inputTimestamp)
    }

    static func mark(_ owner: AnyObject, _ stage: StaticString) {
        if timer.isRecording { timer.mark(ObjectIdentifier(owner), "\(stage)") }
    }

    static func kind(_ owner: AnyObject, _ kind: String) {
        if timer.isRecording { timer.setKind(ObjectIdentifier(owner), kind) }
    }

    /// `owner` shows the new workspace in `window`: a switch begun in this turn ends at its commit.
    static func shown(_ owner: AnyObject, in window: NSWindow?) {
        timer.shown(ObjectIdentifier(owner), in: window)
    }

    /// `owner` already shows the workspace asked for: the switch changes nothing and leaves no sample.
    static func unchanged(_ owner: AnyObject) {
        timer.forget(ObjectIdentifier(owner))
    }
}
