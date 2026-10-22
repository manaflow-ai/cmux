import AppKit
import CmuxNextDesign

/// `debug.space_switch`: the app's own time per space switch (`SwitchFrameTimer`). A switch begins at
/// `WindowManager.switchProfile` and shows once both halves of the window show the new space: the
/// sidebar lists its rows (`SidebarView.onSpaceShown`) and the content area shows its workspace
/// (`WindowController.show`), each a `<stage>_ms` column (`sync`: `switchProfile` returned). The row
/// then waits ``settleWindow`` for the slide that follows, counting the frames it missed.
@MainActor
enum DebugSpaceSwitch {
    static let timer: SwitchFrameTimer = {
        let timer = SwitchFrameTimer(owner: "debug.space_switch")
        timer.settleWindow = 0.6 // the sidebar slide's spring settles well inside this
        return timer
    }()
    /// Per window state: which halves showed the switch in flight.
    private static var halves: [ObjectIdentifier: (sidebar: Bool, content: Bool)] = [:]

    static func began(_ state: WindowState) {
        guard timer.isRecording else { return }
        let event = NSApp.currentEvent
        let input = event.flatMap { [.keyDown, .leftMouseDown, .leftMouseUp].contains($0.type) ? $0.timestamp : nil }
        timer.began(ObjectIdentifier(state), inputTimestamp: input)
        halves[ObjectIdentifier(state)] = (false, false)
    }

    static func mark(_ state: WindowState, _ stage: String) {
        guard timer.isRecording else { return }
        timer.mark(ObjectIdentifier(state), stage)
    }

    static func sidebarShown(_ state: WindowState, in window: NSWindow?) {
        reached(state, in: window) { $0.sidebar = true }
    }

    static func contentShown(_ state: WindowState, in window: NSWindow?) {
        reached(state, in: window) { $0.content = true }
    }

    private static func reached(_ state: WindowState, in window: NSWindow?, _ update: (inout (sidebar: Bool, content: Bool)) -> Void) {
        let key = ObjectIdentifier(state)
        guard timer.isRecording, timer.isWaiting(key), var shown = halves[key] else { return }
        let before = shown
        update(&shown)
        if shown.sidebar != before.sidebar { timer.mark(key, "sidebar") }
        if shown.content != before.content { timer.mark(key, "content") }
        halves[key] = shown
        guard shown.sidebar, shown.content else { return }
        halves[key] = nil
        timer.shown(key, in: window)
    }
}
