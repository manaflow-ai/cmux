/// One interval or event name in the cmux signpost catalog.
///
/// Names are `<category>.<what>` and never change meaning: the Debug benches, the Release benches
/// (`scripts/cmux-next/perf-signposts.py`) and PL-telemetry's opt-in hang reports read the same
/// strings. Add a case here, with what its interval spans, before a call site uses it. The cases
/// are the catalog: `allCases` is the list tests and readers enumerate, so no second list exists.
///
/// ``actionPerform``, ``actionCommit``, ``actionGate``, ``keyToFrame``, ``keyFlow``, ``scrollToFrame``,
/// ``stallMainTask`` and ``stallOverBudget`` have an emitter today. The other cases are
/// **reserved**: the lane named on each adds the emitter (plans/cmux-next/architecture-refactor-DESIGN.md
/// section 7). Until then no build records them, and no bench or report may quote them.
///
/// ```swift
/// let state = Signposter.action.begin(.actionPerform, "id=tab.new")
/// ```
public nonisolated enum SignpostName: Sendable, Hashable, CaseIterable, CustomStringConvertible {
    // MARK: action

    /// From `ActionRegistry` starting an action to its handler returning: the handler's own
    /// synchronous main-thread time. Message: `id=<action id> origin=<origin> input_age_ms=<age>`,
    /// where the age is that of the OS input event AppKit is dispatching for a `user` run, else -1.
    case actionPerform
    /// From `ActionRegistry` starting an action to the end of the next Core Animation commit
    /// (``CommitBoundary``): the synchronous perform plus the commit of what it changed in that
    /// turn. Work the handler defers (an awaited daemon reply, Chromium's `CreateBrowser`, a later
    /// SwiftUI update, a frame client's next display frame) lands in a later commit, so this is
    /// not the time to the frame that shows the action's result: use the action's own end signal
    /// for that. Same begin message as ``actionPerform``; the end message is `commit=missed` when
    /// the boundary missed the turn's commit (see ``CommitBoundary/Outcome/missed``).
    case actionCommit
    /// A gate before an action runs: the confirmation presenter of a destructive action, or the
    /// palette opening to collect a missing argument, from `ActionRegistry` handing over to the
    /// gate until the gate returns (or starts a timed run itself). Not a run of the action: the
    /// run the gate lets through (often in a later turn, after a sheet or a daemon round trip)
    /// has its own ``actionPerform`` and ``actionCommit`` with the age of the gesture that
    /// started it, so readers keep gates out of the action's rows. Same begin message as
    /// ``actionPerform``.
    case actionGate

    // MARK: motion (reserved: PL-motion-core, DisplayLinkDriver)

    /// Reserved. One layout motion frame: the display-link tick to its presentation applied.
    case motionFrame
    /// Reserved. A whole motion: the structural change to the spring at rest.
    case motionRun

    // MARK: key (PL-typing)

    /// A key-down the app dispatches to the end of the Core Animation commit that ends that turn (the app's
    /// `KeyFrameSignpost`, from `CmuxApplication.sendEvent`). Message: `target=<view|terminal> age_ms=<age>`,
    /// the key's age when its dispatch began (its wait in the event queue). For a text view the commit shows
    /// the typed character; for a terminal it is the key's main-thread share, and the echo comes later.
    case keyToFrame
    /// One hop of a key press's flow across processes (a point event, not an interval), emitted only
    /// while `CMUX_NEXT_TRACE_FLOWS` is set (`TypingLatencyProbe`). Message: `hop=<hop> flow=<id>
    /// age_us=<n>`, where `flow` is the id the app minted for the key press (the daemon's `send`
    /// request carries it) and `age_us` the key event's age at the hop, or -1.
    /// scripts/cmux-next/trace.py joins these with the daemon's, host's and holder's flow marks.
    case keyFlow
    /// A scroll event (a trackpad gesture's touch, began, change or end, its momentum, or a mouse-wheel notch)
    /// the app dispatches to the end of the Core Animation commit that ends that turn (``ScrollFrameSignpost``,
    /// from the app's one input dispatch context, as ``keyToFrame``). Begin message: `phase=<touch|began|changed|
    /// ended|momentum|wheel> age_ms=<age>`, the event's wait in the queue. End message: `target=<layout|content>`,
    /// who took it: `layout` when the layout scrolled the strip, rows, an area or a canvas (that commit shows the
    /// move), `content` when it went on to the view under the pointer (a terminal or page may show it in a later
    /// frame); `commit=missed` as for ``actionCommit``.
    case scrollToFrame
    /// A typed palette query (the search field's edit) to the end of the Core Animation commit of the frame that
    /// first shows its final ranked rows (the palette's view, `PaletteQueryFrameMarks`). Message: `scope=<scope>`.
    /// Its end can be a later main-thread turn than the key's (the rank runs off the main thread). A query typed
    /// past before its rows show is never ended (a reader counts it as unpaired). One per typed query.
    case paletteQueryRows
    /// A typed palette query to the end of the commit of the frame that first shows a contributed page's answer
    /// for it (Search's and the Chats & agents scope's agent chats, which acpmux answers in a later turn). End
    /// message: `rows=<n>`, the answer's rows on screen. Never ended for a query typed past or answered empty.
    case paletteQueryAnswer

    // MARK: switch (reserved: PL-switch, SwitchFrameTimer)

    /// Reserved. A workspace switch: the intent to the commit that shows the new workspace.
    case switchWorkspace
    /// Reserved. A tab switch: the intent to the commit that shows the tab's content.
    case switchTab
    /// Reserved. A pane focus move: the intent to the settled focus.
    case switchPaneFocus

    // MARK: create (reserved: PL-cef-tab)

    /// Reserved. A new tab: the intent to its first themed frame. Message: `kind=<terminal|chromium|webkit|chat|page>`.
    case createTab
    /// Reserved. A new workspace: the intent to its sidebar row drawn.
    case createWorkspace

    // MARK: cef (reserved: PL-motion-cef, PL-cef-tab)

    /// Reserved. One Chromium message pump pass on the main thread.
    case cefPump
    /// Reserved. `CefBrowserHost::CreateBrowser` on the main thread.
    case cefCreateBrowser

    // MARK: stall (emitter: the main-thread scheduler, CmuxNextWakeups `MainFrameBudget`)

    /// One task the main-thread scheduler runs, from its start to its return: a frame batch
    /// (`FrameBatcher` work) or a queued control request. Message: `class=<input|frame|visible|automation|background>
    /// owner=<batch owner or control method>`. Per task, so several per frame: never mirrored to MetricKit.
    case stallMainTask
    /// A point event: a scheduled main-thread task ran past its class's per-frame budget. Message:
    /// `class=<class> owner=<owner> ms=<task time> budget_ms=<the class's budget>`.
    case stallOverBudget

    /// The name `os_signpost` records (a compile-time string, as the API requires).
    public var staticName: StaticString {
        switch self {
        case .actionPerform: "action.perform"
        case .actionCommit: "action.commit"
        case .actionGate: "action.gate"
        case .motionFrame: "motion.frame"
        case .motionRun: "motion.run"
        case .keyToFrame: "key.frame"
        case .keyFlow: "key.flow"
        case .scrollToFrame: "key.scroll_frame"
        case .paletteQueryRows: "key.palette_query_rows"
        case .paletteQueryAnswer: "key.palette_query_answer"
        case .switchWorkspace: "switch.workspace"
        case .switchTab: "switch.tab"
        case .switchPaneFocus: "switch.pane_focus"
        case .createTab: "create.tab"
        case .createWorkspace: "create.workspace"
        case .cefPump: "cef.pump"
        case .cefCreateBrowser: "cef.create_browser"
        case .stallMainTask: "stall.main_task"
        case .stallOverBudget: "stall.over_budget"
        }
    }

    /// The category whose ``Signposter`` emits this name: the part of the name before the first
    /// dot. Nil only for a malformed name, which the catalog test refuses.
    public var category: SignpostCategory? {
        SignpostCategory(rawValue: String(description.prefix { $0 != "." }))
    }

    /// The name as a `String`.
    public var description: String { staticName.withUTF8Buffer { String(decoding: $0, as: UTF8.self) } }
}
