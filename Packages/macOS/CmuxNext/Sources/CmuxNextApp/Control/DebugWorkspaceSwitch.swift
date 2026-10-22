import AppKit
import CmuxNextDesign
import os

/// `debug.workspace_switch`: the app's own time per workspace switch (`SwitchFrameTimer`), as `debug.tab_switch`
/// times a tab switch (Lawrence 2026-10-21: "switching workspaces is very slow ... on mousedown, instantly switch").
/// Per switch: `input_ms` (the press or key's age when the switch began, absent for a socket action), `apply_ms` to
/// the swapped content (`WindowController.show`), `commit_ms` to the Core Animation commit that carries it, its
/// `late_vsyncs`, and one `<stage>_ms` per stage: `park` (the old content parked), `content` (the new controller kept
/// or built), `swap` (the content view in the window), `theme`, `did_show` (panes restored), `side` (the
/// observers, record save and context hooks after it). `kind` is `warm` (a parked controller came back) or `cold`
/// (built now). Every switch is also an `OSSignposter` interval (subsystem `com.cmuxterm.app.next`, category
/// `workspace-switch`, name `switch`), recording or not.
@MainActor
enum DebugWorkspaceSwitch {
    static let timer = SwitchFrameTimer(owner: "debug.workspace_switch")
    private static let signposter = OSSignposter(subsystem: "com.cmuxterm.app.next", category: "workspace-switch")
    private static var intervals: [ObjectIdentifier: (id: OSSignpostID, state: OSSignpostIntervalState)] = [:]

    /// A switch in the window of `owner` begins (its press, key or action is the current event, if any).
    static func began(_ owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        if signposter.isEnabled {
            if let open = intervals.removeValue(forKey: key) { signposter.endInterval("switch", open.state, "superseded") }
            let id = signposter.makeSignpostID()
            intervals[key] = (id, signposter.beginInterval("switch", id: id))
        }
        guard timer.isRecording else { return }
        let event = NSApp.currentEvent
        let input = event.flatMap { [.leftMouseDown, .leftMouseUp, .keyDown].contains($0.type) ? $0.timestamp : nil }
        timer.began(key, inputTimestamp: input)
    }

    /// The switch of `owner` reached `stage`.
    static func mark(_ owner: AnyObject, _ stage: StaticString) {
        if let open = intervals[ObjectIdentifier(owner)] { signposter.emitEvent(stage, id: open.id) }
        if timer.isRecording { timer.mark(ObjectIdentifier(owner), "\(stage)") }
    }

    static func kind(_ owner: AnyObject, _ kind: String) {
        if timer.isRecording { timer.setKind(ObjectIdentifier(owner), kind) }
    }

    /// The new workspace is in `window`: the transaction open now carries it to the screen.
    static func shown(_ owner: AnyObject, in window: NSWindow?) {
        if let open = intervals.removeValue(forKey: ObjectIdentifier(owner)) { signposter.endInterval("switch", open.state) }
        timer.shown(ObjectIdentifier(owner), in: window)
    }
}
