import AppKit
import CmuxNextDesign

/// `debug.workspace_switch`: the app's own time per workspace switch (`SwitchFrameTimer`), from the
/// intent (`WindowManager.show(workspaceID:in:)`, every entry: a sidebar click, Cmd-1…9, next or
/// previous workspace, the palette, a socket action) to the shown content (`WindowController.show`)
/// to the Core Animation commit that carries it. `input_ms` is the triggering event's age (a click's
/// release, a key), so a switch that waits on its event shows there. Stages: `park`, `sidebar`,
/// `root`, `theme`, `did_show` (since the intent). Lawrence 2026-10-21: "changing workspaces is laggy".
@MainActor
enum DebugWorkspaceSwitch {
    static let timer = SwitchFrameTimer(owner: "debug.workspace_switch")
    /// The window whose switch is timed now (a switch is keyed by its window's state).
    static func began(_ owner: AnyObject) {
        guard timer.isRecording else { return }
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

    static func shown(_ owner: AnyObject, in window: NSWindow?) {
        if timer.isRecording { timer.shown(ObjectIdentifier(owner), in: window) }
    }
}
