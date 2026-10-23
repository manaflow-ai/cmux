import AppKit
import CmuxNextDesign

/// `debug.input_commit`: for any key (`debug.key`) or click (`debug.mouse`, a real click too), the time
/// from the input event to the Core Animation commit of the transaction its dispatch left open
/// (`SwitchFrameTimer`): `input_ms` is the event's age when its dispatch began, `apply_ms` the
/// dispatch itself (the work on the input's turn), `commit_ms` the commit. One row per input, its
/// `kind` the event (`keyDown`, `mouseDown`, `mouseUp`), and `workspace_shown` the workspace contents
/// its dispatch showed in its own turn (a space or workspace switch shows 1; a switch left to a later
/// observation turn shows 0). It times what no switch-specific timer covers (a space switch, a group
/// collapse); work an input defers past its turn is not in it.
@MainActor
enum DebugInputCommit {
    static let timer = SwitchFrameTimer(owner: "debug.input_commit")
    private static let key = "input"

    /// Times `body`, the dispatch of `event` to `window`, when recording.
    static func dispatching<T>(_ event: NSEvent, in window: NSWindow?, _ body: () -> T) -> T {
        guard timer.isRecording, let kind = kind(of: event.type) else { return body() }
        timer.began(key, inputTimestamp: event.timestamp)
        timer.setKind(key, kind)
        let shows = DebugWorkspaceSwitch.shows
        let result = body()
        timer.shown(key, in: window, extra: ["workspace_shown": Double(DebugWorkspaceSwitch.shows &- shows)])
        return result
    }

    private static func kind(of type: NSEvent.EventType) -> String? {
        switch type {
        case .keyDown: "keyDown"
        case .leftMouseDown: "mouseDown"
        case .leftMouseUp: "mouseUp"
        default: nil
        }
    }
}
