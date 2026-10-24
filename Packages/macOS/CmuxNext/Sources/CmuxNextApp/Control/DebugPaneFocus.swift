import AppKit
import CmuxNextControl
import CmuxNextDesign
import CmuxNextSettings
import os

/// `debug.pane_focus`: the app's own time per pane focus move (`SwitchFrameTimer`), apart from the
/// socket reply: the intent (a pane-navigation key, a click, `pane.focus`) to the settled focus
/// (`FocusCoordinator.send` drained: reduced, effects applied, settle observers run), then to the Core
/// Animation commit that carries it (scripts/cmux-next/perf-gate.py, scenario `pane_focus`).
/// Stages: `reduced_ms` (the reducer returned), `applied_ms` (its effects ran), `settled_ms`
/// (the settle observers ran). Every move is also an `OSSignposter` interval (subsystem
/// `com.cmuxterm.app.next`, category `pane-focus`, name `move`), recording or not.
@MainActor
enum DebugPaneFocus {
    static let timer = SwitchFrameTimer(owner: "debug.pane_focus")
    private static let signposter = OSSignposter(subsystem: "com.cmuxterm.app.next", category: "pane-focus")
    private static var interval: OSSignpostIntervalState?
    /// Main-thread work of `kind` runs now (a window record save, a trail encode): every switch timer
    /// counts it while a recorded switch waits for its commit (`work_before_commit`).
    static func noteMainWork(_ kind: String) {
        for each in [timer, DebugWorkspaceSwitch.timer, DebugTabSwitch.timer] { each.noteWork(kind) }
    }

    /// `debug.pane_focus`: the timer's moves, plus `work_before_commit` (reset by `start`).
    static func handle(_ params: [String: JSONValue]) -> JSONValue {
        #if DEBUG
        if params["action"]?.stringValue == "start" { DebugChromiumRestorableState.reset() }
        #endif
        guard case .object(var object) = timer.handle(params, key: "moves") else { return .null }
        #if DEBUG
        // Chromium page windows' restorable-state encodes since `start` (WindowServer round trips).
        object["chromium_restorable_encodes"] = .number(Double(DebugChromiumRestorableState.encodes))
        #endif
        return .object(object)
    }

    /// A pane focus move of `coordinator` starts now (the earliest caller wins until it shows).
    static func began(_ coordinator: FocusCoordinator) {
        if signposter.isEnabled, interval == nil { interval = signposter.beginInterval("move") }
        guard timer.isRecording, !timer.isWaiting(ObjectIdentifier(coordinator)) else { return }
        timer.began(ObjectIdentifier(coordinator), inputTimestamp: (NSApp as? CmuxApplication)?.isHandlingSendEvent() == true ? NSApp.currentEvent?.timestamp : nil)
    }

    static func mark(_ coordinator: FocusCoordinator, _ stage: String) {
        if timer.isRecording { timer.mark(ObjectIdentifier(coordinator), stage) }
    }

    /// The move settled on a new pane; `window` commits it.
    static func shown(_ coordinator: FocusCoordinator, in window: NSWindow?) {
        if let open = interval { signposter.endInterval("move", open); interval = nil }
        timer.shown(ObjectIdentifier(coordinator), in: window)
    }

    /// A drain that began a move but kept the pane (a refused or no-op move): no sample.
    static func dropped(_ coordinator: FocusCoordinator) {
        if let open = interval { signposter.endInterval("move", open, "unchanged"); interval = nil }
        if timer.isRecording { timer.forget(ObjectIdentifier(coordinator)) }
    }
}
