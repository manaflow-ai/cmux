import AppKit
import CmuxNextControl
import CmuxNextDesign
import CmuxNextFocus
import CmuxNextFocusUI
import CmuxNextSettings
import CmuxNextSignposts

/// `debug.pane_focus`: the app's own time per pane focus move (`SwitchFrameTimer`), apart from the
/// socket reply: the intent (a pane-navigation key, a click, `pane.focus`) to the settled focus
/// (`FocusCoordinator.send` drained: reduced, effects applied, settle observers run), then to the Core
/// Animation commit that carries it (scripts/cmux-next/perf-gate.py, scenario `pane_focus`).
/// Stages: `reduced_ms` (the reducer returned), `applied_ms` (its effects ran), `settled_ms`
/// (the settle observers ran).
///
/// Every move is also the `switch.pane_focus` trace interval in every build, recording or not: an
/// `os_signpost` interval and a ring async pair (AB/AE) from the focus intent (begin `arg0`: the input
/// age in microseconds, all ones without an input event) to the `CommitBoundary` after the turn whose
/// drain settled focus on the new pane. A drain that keeps the pane (a refused or no-op move) ends it as
/// missed (`commit=missed`), so readers and MetricKit drop it. Only an intent opens one: a user-sourced
/// event aimed at another pane of the shown workspace, or an explicit ``began(_:)``; the drains of daemon
/// deltas, responder echoes, topology reports and moves in a hidden workspace (the reducer only remembers
/// those) write nothing. A recorded row starts at the interval's begin and its `signpost_ms` is the
/// interval. Each coordinator times into its ``FocusCoordinator/paneFocusTimer`` (``timer`` unless a test
/// passes its own) and reads its input from its ``FocusCoordinator/keyInput`` and ``FocusCoordinator/inputDispatch``.
///
/// Chrome has no focus-move metric: a click or key that moves focus is an input event, timed by
/// EventLatency from the event's timestamp to the frame that presents its effect (cc/metrics/event_metrics.h,
/// cc/metrics/compositor_frame_reporter.cc). This interval is that span for the focus move, in the
/// `SwitchFrameTimer` shape cmux's other switches share, so one reader handles them all.
@MainActor
enum DebugPaneFocus {
    static let timer = SwitchFrameTimer(owner: "debug.pane_focus", signpost: SignpostName.switchPaneFocus)
    /// Main-thread follow-up work that ran after a move settled and before its commit, by kind
    /// (`record_saves`): work that can push the move's frame late.
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

    /// A pane focus move of `coordinator` starts now. The earliest caller wins until it shows: a
    /// pane-navigation key's begin, made before it sends its event, holds through the drain that event starts.
    static func began(_ coordinator: FocusCoordinator) {
        let key = ObjectIdentifier(coordinator), timer = coordinator.paneFocusTimer
        guard !timer.awaitsShow(key) else { return }
        // The key whose binding runs now (KeyRouter), else the input the move answers (InputDispatchContext.inputTimestamp).
        timer.began(key, inputTimestamp: coordinator.keyInput?.timestamp ?? coordinator.inputDispatch?.inputTimestamp)
    }

    /// A drain of `coordinator` starts with `event`: a move begins when the event is a focus intent.
    /// Returns whether it is one, so the drain ends it (``shown(_:in:)`` or ``dropped(_:)``).
    static func began(_ coordinator: FocusCoordinator, for event: FocusEvent) -> Bool {
        guard aimsAtAnotherPane(event, in: coordinator.state) else { return false }
        began(coordinator)
        return true
    }

    static func mark(_ coordinator: FocusCoordinator, _ stage: String) {
        let timer = coordinator.paneFocusTimer
        if timer.isRecording { timer.mark(ObjectIdentifier(coordinator), stage) }
    }

    /// The move settled on a new pane; `window` commits it, and the turn's boundary ends the interval.
    static func shown(_ coordinator: FocusCoordinator, in window: NSWindow?) {
        coordinator.paneFocusTimer.shown(ObjectIdentifier(coordinator), in: window)
    }

    /// An intent's drain kept the pane (a refused or no-op move): no sample, the interval ends as missed.
    static func dropped(_ coordinator: FocusCoordinator) {
        coordinator.paneFocusTimer.forget(ObjectIdentifier(coordinator))
    }

    /// A user-sourced event that names a pane of `state`'s shown workspace other than the focused one: a
    /// pane focus intent. An event for another workspace only remembers its pane (cmux-focus-core reducer.rs).
    nonisolated static func aimsAtAnotherPane(_ event: FocusEvent, in state: FocusState) -> Bool {
        let shown = { (workspace: String?) in workspace == nil || workspace == state.topology.workspace }
        let target: String?
        switch event {
        case .focusPane(let pane, let workspace, let source) where source.isUserIntent && shown(workspace): target = pane
        case .selectTab(let pane, _, let workspace, let source) where source.isUserIntent && shown(workspace): target = pane
        case .responder(let responder, let source) where source.isUserIntent:
            switch responder {
            case .content(let pane), .addressBar(let pane), .findBar(let pane), .devTools(let pane): target = pane
            case .sidebar, .sidebarField, .textField, .windowOrNone: target = nil
            }
        default: target = nil
        }
        return target.map { $0 != state.pane } ?? false
    }
}
