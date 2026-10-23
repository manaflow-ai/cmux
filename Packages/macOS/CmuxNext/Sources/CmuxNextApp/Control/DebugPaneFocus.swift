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
    /// Main-thread follow-up work that ran after a move settled and before its commit, by kind
    /// (`record_saves`, `trail_encodes`): work that can push the move's frame late.
    private(set) static var workBeforeCommit: [String: Int] = [:]

    /// Main-thread work of `kind` runs now: counted while a recorded move waits for its commit.
    static func noteMainWork(_ kind: String) {
        guard timer.isRecording, timer.awaitsCommit else { return }
        workBeforeCommit[kind, default: 0] += 1
    }

    /// `debug.pane_focus`: the timer's moves, plus `work_before_commit` (reset by `start`).
    static func handle(_ params: [String: JSONValue]) -> JSONValue {
        if params["action"]?.stringValue == "start" {
            workBeforeCommit = [:]
            #if DEBUG || CMUX_BENCH_HOOKS
            DebugChromiumRestorableState.reset()
            #endif
        }
        guard case .object(var object) = timer.handle(params, key: "moves") else { return .null }
        object["work_before_commit"] = .object(workBeforeCommit.mapValues { .number(Double($0)) })
        #if DEBUG || CMUX_BENCH_HOOKS
        // Chromium page windows' restorable-state encodes since `start` (WindowServer round trips).
        object["chromium_restorable_encodes"] = .number(Double(DebugChromiumRestorableState.encodes))
        #endif
        return .object(object)
    }

    /// A pane focus move of `coordinator` starts now (the earliest caller wins until it shows).
    static func began(_ coordinator: FocusCoordinator) {
        if signposter.isEnabled, interval == nil { interval = signposter.beginInterval("move") }
        guard timer.isRecording, !timer.isWaiting(ObjectIdentifier(coordinator)) else { return }
        let event = (NSApp as? CmuxApplication)?.isHandlingSendEvent() == true ? NSApp.currentEvent : nil
        timer.began(ObjectIdentifier(coordinator), inputTimestamp: event?.timestamp)
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
