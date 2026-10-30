/// One interval or event name in the cmux signpost catalog.
///
/// Names are `<category>.<what>` and never change meaning: the Debug benches, the Release benches
/// (`scripts/cmux-next/perf-signposts.py`), the Release trace ring and PL-telemetry's opt-in hang
/// reports read the same strings. The cases are the catalog: `allCases` is the list tests and readers
/// enumerate, so no second list exists.
///
/// The raw value is the name's id in the Release trace ring (a record stores this `UInt16`, the ring
/// header stores the id-to-name table). Ids are fixed and append-only: a new case takes the next free
/// id, and an id is never reused, so a ring written by an older build decodes. The catalog was frozen
/// for the p09-observability program (plans/cmux-next/chrome-parity/p09-observability.md, task 000):
/// an emitter task uses these cases and does not edit this file; a missing name is a follow-up to
/// task 000 that the lead merges.
///
/// ``actionPerform``, ``actionCommit``, ``actionGate``, ``keyToFrame``, ``keyFlow``, ``scrollToFrame``,
/// ``stallMainTask``, ``stallOverBudget``, ``stallMainTurn`` (the trace ring's), ``stallRenderStarved``,
/// ``launchStartupTask``, ``launchStartupComplete``, ``launchReadDone``, ``stallPaletteOpen``, ``stallIconPickerOpen``,
/// ``webuiOpen``, ``webuiScheme``, ``stallCreateSurface``, ``daemonStep``, ``webuiAgentPaneStep``, ``createTab``,
/// ``createWorkspace``, ``stallGhosttyRuntimePhase``, ``switchWorkspace``, ``switchTab``, ``switchPaneFocus``,
/// ``burstEvent``, ``motionLateCommits``, ``actionPresentedEstimate``, ``cefMemoryPressureVote`` and
/// ``launchActionCatalogFirstMainAccess`` have an emitter
/// today. The
/// other cases are **reserved**: the task and owner named on each add the emitter. Until then no build records them,
/// and no bench or report may quote them. "Ring" on a reserved case gives its record phases and the
/// meaning of `arg0` and `arg1` (the ring v1 record, plans/cmux-next/trace.md).
///
/// ```swift
/// let state = Signposter.action.begin(.actionPerform, "id=tab.new")
/// ```
public nonisolated enum SignpostName: UInt16, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    // MARK: action

    /// From `ActionRegistry` starting an action to its handler returning: the handler's own
    /// synchronous main-thread time. Message: `id=<action id> origin=<origin> input_age_ms=<age>`,
    /// where the age is that of the OS input event AppKit is dispatching for a `user` run, else -1.
    case actionPerform = 1
    /// From `ActionRegistry` starting an action to the end of the next Core Animation commit
    /// (``CommitBoundary``): the synchronous perform plus the commit of what it changed in that
    /// turn. Work the handler defers (an awaited daemon reply, Chromium's `CreateBrowser`, a later
    /// SwiftUI update, a frame client's next display frame) lands in a later commit, so this is
    /// not the time to the frame that shows the action's result: use the action's own end signal
    /// for that. Same begin message as ``actionPerform``; the end message is `commit=missed` when
    /// the boundary missed the turn's commit (see ``CommitBoundary/Outcome/missed``).
    case actionCommit = 2
    /// A gate before an action runs: the confirmation presenter of a destructive action, or the
    /// palette opening to collect a missing argument, from `ActionRegistry` handing over to the
    /// gate until the gate returns (or starts a timed run itself). Not a run of the action: the
    /// run the gate lets through (often in a later turn, after a sheet or a daemon round trip)
    /// has its own ``actionPerform`` and ``actionCommit`` with the age of the gesture that
    /// started it, so readers keep gates out of the action's rows. Same begin message as
    /// ``actionPerform``.
    case actionGate = 3

    // MARK: motion (reserved: PL-motion-core, DisplayLinkDriver)

    /// One layout motion frame: the display-link tick to its presentation applied (`LayoutMotionTrace`,
    /// `Signposter.beginMotionFrame`). Ring: B/E, one per window per tick; begin arg0 the panes the frame moves
    /// (all of a screen whose frame or camera springs), arg1 the tick's dt in us.
    case motionFrame = 4
    /// A whole layout motion: the structural change to the motion at rest, on the CPU step or the render server
    /// (`LayoutMotionTrace`), one per window at a time; mirrored to MetricKit. Ring: AB/AE; end arg0 the CPU
    /// frames in bits 0-31 and the longest of them in us in bits 32-63 (`Signposter.motionRunResult`; arg1 is the
    /// async id).
    case motionRun = 5
    /// One tab drag ghost tick (task 039, perf-hot `drag-frame`; `TabDragSession.tick`): the ghost's spring step,
    /// the autoscroll, the drop-target hit test and the render. Ring: B/E, one per tick of the drag or of its
    /// landing flight (a tick for a drag that ended writes none); begin arg0 the tick's dt in whole us (0 for a
    /// negative or NaN dt, saturated at `UInt32.max`); end arg0 0.
    case motionDragFrame = 18

    // MARK: key (PL-typing)

    /// A key-down the app dispatches to the end of the Core Animation commit that ends that turn (begun with the
    /// key's input latency slot in `CmuxApplication.sendEvent`, CmuxNextInput's `InputFrameSignposts`). Message: `target=<view|terminal> age_ms=<age>`,
    /// the key's age when its dispatch began (its wait in the event queue). For a text view the commit shows
    /// the typed character; for a terminal it is the key's main-thread share, and the echo comes later.
    /// Ring: AB/AE keyed by its `OSSignpostID`; begin arg0 the target (1 view, 2 terminal) in bits 0-7 and the
    /// age in us in the top 24; end arg0 how it ended.
    case keyToFrame = 6
    /// One hop of a key press's flow across processes (a point event, not an interval), emitted only
    /// while `CMUX_NEXT_TRACE_FLOWS` is set (`TypingLatencyProbe`). Message: `hop=<hop> flow=<id>
    /// age_us=<n>`, where `flow` is the id the app minted for the key press (the daemon's `send`
    /// request carries it) and `age_us` the key event's age at the hop, or -1.
    /// scripts/cmux-next/trace.py joins these with the daemon's, host's and holder's flow marks.
    case keyFlow = 7
    /// A scroll event that opens an input latency slot (a trackpad gesture's began or change, its moving momentum,
    /// or a mouse-wheel notch) from its dispatch to the end of the Core Animation commit that ends that turn (begun
    /// with the slot, as ``keyToFrame``; ``ScrollFrameSignpost`` writes the same messages). Begin message:
    /// `phase=<began|changed|momentum|wheel> age_ms=<age>` (older builds also wrote `touch` and `ended`), the
    /// event's wait in the queue. End message: `target=<layout|content>`,
    /// who took it: `layout` when the layout scrolled the strip, rows, an area or a canvas (that commit shows the
    /// move), `content` when it went on to the view under the pointer (a terminal or page may show it in a later
    /// frame); `commit=missed` as for ``actionCommit``.
    case scrollToFrame = 8
    /// One synchronous pass of the omnibar's suggestions for a typed key (task 040, PL-typing; perf-hot
    /// `omnibar-key`; ``Signposter/begin(_:searchPass:)``): the reducer pass that takes the query
    /// (`OmnibarStep.refreshSuggestions`), or the one that reduces its rows when they land. Begin message
    /// `pass=<code>`, end message `results=<count>`. Ring: B/E; begin arg0 the ``Signposter/KeySearchPass``
    /// code (1 query, 2 rows, 3 more rows), end arg0 the popup's rows at the pass's end.
    case keyOmnibarSuggest = 19
    /// One synchronous pass of a Command Palette search for a typed key (task 040; perf-hot `palette-key`;
    /// ``Signposter/begin(_:searchPass:)``): `PaletteModel.search` handing the query to the ranker, or the
    /// pass that shows its ranked rows when they land. Messages as ``keyOmnibarSuggest``. Ring: B/E; begin arg0
    /// the ``Signposter/KeySearchPass`` code (1 query, 2 rows), end arg0 the page's rows at the pass's end.
    case keyPaletteSearch = 20

    // MARK: key echo hops (reserved: task 102, PL-trace)
    // The 12 thread handoffs of a key's echo (ghostty-integration-DESIGN.md, "Key to frame"): a flow-out
    // when a thread queues the item, a flow-in when the next thread takes it, under the same name. Ring:
    // arg0 the terminal hash, arg1 the key's flow id. The Rust and C writers use the same strings.

    /// Reserved (task 102, PL-trace). The terminal host's PTY thread: the echo read from the PTY.
    case keyEchoHostPTYRead = 21
    /// Reserved (task 102, PL-trace). The terminal host's client writer: the output frame to the daemon.
    case keyEchoHostClientWrite = 22
    /// Reserved (task 102, PL-trace). The daemon's frames thread: the host frame taken off the socket.
    case keyEchoDaemonFrames = 23
    /// Reserved (task 102, PL-trace). The daemon's surface parse of the output.
    case keyEchoSurfaceParse = 24
    /// Reserved (task 102, PL-trace). The daemon's attach-out encode of the output event.
    case keyEchoAttachEncode = 25
    /// Reserved (task 102, PL-trace). The daemon's line-out writer: the event written to the app socket.
    case keyEchoLineOut = 26
    /// Reserved (task 102, PL-trace). The app's transport reader (`LineTransport`): the line read.
    case keyEchoAppTransportRead = 27
    /// Reserved (task 102, PL-trace). The hop to the main actor.
    case keyEchoMainActor = 28
    /// Reserved (task 102, PL-trace). The terminal output lane (`TerminalOutputLane`): the bytes fed to Ghostty.
    case keyEchoOutputLane = 29
    /// Reserved (task 102, PL-trace). Ghostty's renderer thread: the frame that draws the echo.
    case keyEchoRenderer = 30
    /// Reserved (task 102, PL-trace). The Metal completion handler of that frame.
    case keyEchoGPUDone = 31
    /// Reserved (task 102, PL-trace). The main thread's IOSurface contents handoff of that frame.
    case keyEchoContents = 32

    // MARK: switch (PL-switch)

    /// A workspace switch (task 027, `DebugWorkspaceSwitch`, every build): the intent
    /// (`WindowManager.show(workspaceID:in:)`) to the ``CommitBoundary`` after its turn, which shows the new
    /// workspace. An intent that shows nothing in its turn, or a superseded one, ends `commit=missed`. Ring: AB/AE;
    /// begin arg0 the input age in us (all ones without an input event); end arg0 the boundary's `EndCode`.
    case switchWorkspace = 9
    /// A tab switch (``TabSwitchSignpost``, every build): the intent to the app's commit that shows the destination
    /// tab's content. Begin message `kind=<cold|warm|page>`. A switch to a live Chromium page ends at the commit after
    /// its page window's show (`tab_activate`), before Chromium presents the tab: that end says `end=page_activated`
    /// and is not mirrored to MetricKit. A superseded switch, or one whose pane went away or hid, ends `commit=missed`.
    /// Ring: AB/AE keyed by its `OSSignpostID`; begin arg0 the kind (0 cold, 1 warm, 2 page) in bits 0-7 and the
    /// input age in us in the top 24 (all ones without an input event); end arg0 the end code (0 ended, 1 missed,
    /// 3 page activated).
    case switchTab = 10
    /// A pane focus move (task 029, `DebugPaneFocus`): a user's focus intent aimed at another pane of the shown
    /// workspace to the ``CommitBoundary`` after the turn that settled focus on the new pane. Ring: AB/AE;
    /// begin arg0 the input age in us (all ones without an input event); end arg0 the boundary's `EndCode`
    /// (0 committed, 1 `commit=missed`: a refused, no-op or superseded move, which readers drop).
    case switchPaneFocus = 11
    /// A key or activation change that flips a window's look (task 039, perf-hot `cmd-tab`; `WindowKeyFamily.check`,
    /// ``Signposter/beginAppActivation(noticeCode:noticeName:appActivation:noticeAgeMilliseconds:)``): the window's
    /// key tracker turning its inactive wash on or off to the ``CommitBoundary`` after that turn. One per window whose
    /// look flipped: a window whose look stays, or one with no material view left, writes none, so a Cmd-Tab back is
    /// one slice and a focus move between two windows at most two. Begin message `notice=<name> app=<0|1>
    /// age_ms=<age>`. Ring: AB/AE keyed by its `OSSignpostID`; begin arg0 the turn's first notice in bits 0-7 (a window
    /// did become key 1, resign key 2, become main 3, resign main 4; the app did become active 5, resign active 6),
    /// bit 8 set when the turn had the app's become or resign active notice (a Cmd-Tab; clear for a focus move in the
    /// app), and that first notice's age at the flip in us in the top 24; end arg0 the boundary's `EndCode`
    /// (0 committed, 1 `commit=missed`, which readers drop).
    case switchAppActivation = 33

    // MARK: create (PL-cef-tab)

    /// A new tab (``CreateTabInterval``, every build): the intent's turn to its first themed content frame, or the
    /// ``CommitBoundary`` that shows content with no frame signal of its own. Begin message
    /// `kind=<terminal|chromium|webkit|chat|page>`, end message `outcome=<shown|closed|hidden|missed>`; only shown is a
    /// create latency. Ring: AB/AE keyed by the intent id; begin arg0 the kind, end arg0 the outcome (0 shown, 1 closed,
    /// 2 hidden, 3 missed). Instants, on the intent id (`CreateTabInterval.Scope`): the stand-in commit (arg0 the
    /// kind, arg1 the intent id) and a chat open's stages (`ChatOpenStage`: arg0 the chat kind with the stage's code
    /// in bits 8-15, arg1 the intent id; message `kind=chat stage=<name>`), which may come after the end.
    case createTab = 12
    /// A new workspace (`SidebarNewRowTimer`, every build): its create to the ``CommitBoundary`` after the list reload
    /// that first lists its row; `input_age_ms=<age>` (the press's own input, -1 for a script). A row gone before it
    /// was drawn, or not drawn within 10 s, ends `commit=missed`. Ring: AB/AE; begin arg0 the input age in us in
    /// the top 24 bits (all ones without one); end arg0 the end code (0 ended, 1 missed).
    case createWorkspace = 13

    // MARK: cef (reserved: PL-motion-cef, PL-cef-tab)

    /// One Chromium message pump pass (task 032, ``Signposter/beginCEFPump(reasonCode:)``): `CefDoMessageLoopWork`
    /// on the app's main thread while the pump is in the app; with the Chromium host on, the host emits it (task 104).
    /// Ring: B/E, only while `task` is on too (a recording; never the black box); begin arg0 the reason (1 now,
    /// 2 delayed, 3 kept, 4 the pass a nested run loop's fire deferred; 0 a pass no timer armed), end arg0 1 for a
    /// long run (CEF's whole time slice), arg1 the elapsed us.
    case cefPump = 14
    /// Reserved (task 033, PL-cef-tab). `CefBrowserHost::CreateBrowser` on the main thread, or the Chromium
    /// host's create to its reply. Ring: AB/AE; begin arg0 bit 0 1 for a spare, bits 8-39 the profile index.
    case cefCreateBrowser = 15
    /// A parent geometry change or catcher sync, an I per page post (``Signposter/beginCEFGeometry(_:)``). Ring: B/E/I
    /// only with `motion` on too (never the black box); begin arg0 the source, end arg0/arg1 catchers shown/moved.
    case cefGeometry = 34
    /// One input frame (mouse, wheel, key, edit) written to the Chromium host (``Signposter/cefHostInput(_:)``). Ring:
    /// I only with `input` on too (never the black box); arg0 the wire kind; key and edit obey the keystroke gate.
    case cefHostInput = 35

    // MARK: launch (reserved: task 034, Performance Lead)
    // Each is an async slice from the process start (PROC_PIDTBSDINFO, on the uptime clock) to its mark.
    // Ring: AB/AE; end arg0 the launch temperature, `LaunchClock.Temperature`'s raw value (0 warm, 1 lukewarm,
    // 2 cold, 3 undetermined).

    /// Reserved (task 034, Performance Lead). The process start to the first line of `main`.
    case launchProcessToMain = 36
    /// Reserved (task 034, Performance Lead). The process start to the first window ordered front.
    case launchFirstWindow = 37
    /// Reserved (task 034, Performance Lead). The process start to the first window's first frame (`StartupScheduler.firstFrameCommitted`).
    case launchFirstFrame = 38
    /// Reserved (task 034, Performance Lead). The process start to the daemon connection's handshake.
    case launchDaemonReady = 39
    /// Reserved (task 034, Performance Lead). The process start to the first terminal's first output.
    case launchFirstTerminalOutput = 40

    // MARK: stall (emitter: the main-thread scheduler, CmuxNextWakeups `MainFrameBudget`)

    /// One task the main-thread scheduler runs, from its start to its return: a frame batch
    /// (`FrameBatcher` work) or a queued control request. Message: `class=<input|frame|userBlocking|visible|automation|background>
    /// owner=<batch owner or control method>`. Per task, so several per frame: never mirrored to MetricKit.
    case stallMainTask = 16
    /// A point event: a scheduled main-thread task ran past its class's per-frame budget. Message:
    /// `class=<class> owner=<owner> ms=<task time> budget_ms=<the class's budget>`. Ring: I; arg0 the owner id in
    /// bits 0-31, the class code in bits 32-39 and the budget in us in the top 24; arg1 the task's own time in ns.
    case stallOverBudget = 17
    /// Creating a terminal surface on main (`ghostty_surface_new`, `TerminalTimings`; task 035, PL-ghostty). Ring: B/E.
    case stallCreateSurface = 41
    /// A command palette open's main-thread work (task 036, `PaletteController.open(relativeTo:anchor:when:buildModel:)`
    /// and the re-show after a refused command): the scopes configured, the start mark, the page's model built and the
    /// panel shown, in one synchronous call. The first frame's commit runs in a later turn, outside it (debug.timings'
    /// `palette_opens` row has it). Ring: B/E; arg0 0.
    case stallPaletteOpen = 42
    /// An icon picker open's main-thread work (task 036, `IconPickerService.pick`): the catalog in hand to the panel
    /// shown, in one synchronous call. A first open's catalog load runs off the main actor before it. Ring: B/E; arg0 0.
    case stallIconPickerOpen = 43
    /// A point event: rendering starved (Chrome's `kRenderingStarved`). A display link that paces
    /// active frame clients and whose frames show went over 100 ms and a frame without a tick
    /// (`RenderStarvationGuard`, p06-scheduler task 004; the app's composition root builds it). With
    /// the feature `renderStarvationGuard` on, the main-thread scheduler holds its budgeted work until
    /// that tick. Once per late period, at the first budget check or the late tick. Message:
    /// `link=<scheduler> gap_ms=<time since its last tick> turn=<the turn meter's top unattributed turn,
    /// or unattributed> turn_ms=<its length> unattributed_ms=<its unattributed part>`. Ring: instant.
    case stallRenderStarved = 74

    // MARK: daemon (reserved: task 025, PL-daemon)
    /// Reserved (task 025, PL-daemon). One app request to the cmux-tui daemon, from the send to the reply
    /// or the timeout. Ring: AB/AE keyed by the request id; begin arg0 the command id (`DaemonCommandName`),
    /// end arg0 the outcome (0 reply, 1 error, 2 timeout). Task 103 links it to the daemon's side by a flow.
    case daemonRequest = 44

    // MARK: frame (reserved: PL-motion-core, PL-ghostty)
    /// Task 037 (perf-hot `frame-tick`). One display-link tick (``FramePresentEstimate``, from `DisplayClock`).
    /// Ring: instant; arg0 the tick's timestamp (uptime ns), arg1 its display (`CGDirectDisplayID`) in the high
    /// 32 bits and the nanoseconds from the timestamp to its vsync target in the low 32.
    case frameTick = 45
    /// Task 037. A main run-loop turn's commit, once per turn end after Core Animation's commit observer
    /// (``FramePresentEstimate/observeCommits()``). Ring: instant; arg0 the first key flow it carries (0: none),
    /// arg1 how many it carries.
    case frameCommit = 46
    /// Task 049. A Ghostty frame's Metal completion (`GhosttyTraceHook`). Ring: instant; arg0 surface id, arg1 frame seq.
    case frameGPUDone = 47
    /// Task 037. The first vsync of the flow's display at or after max(``frameCommit``, ``frameGPUDone``)
    /// for a flow-marked commit: an estimate, not a measured present. Ring: instant with the "estimated" flag;
    /// arg0 the flow id, arg1 the vsync target (uptime ns).
    case framePresentEstimate = 48
    /// Reserved (task 057, PL-motion-core). A frame sequence's summary when it closes (Chrome's
    /// `FrameSequenceTracker`). Ring: instant; arg0 expected frames, arg1 frames that committed changes.
    case frameSequence = 49

    // MARK: task (task 042, Performance Lead)
    /// Task 042 (``TaskTrace``). A work item posted to a ``BackgroundWork`` lane or accepted by the control
    /// queue (Chrome's `TaskAnnotator::WillQueueTask` with `FROM_HERE`); a refused item writes none. Ring:
    /// flow-out; arg0 the post site (the interned `#fileID`'s id in bits 0-15, the line in bits 16-47), arg1 the
    /// flow id (bit 63 set).
    case taskPost = 50
    /// A posted item's run (Chrome's `ThreadPool_RunTask`): a BackgroundWork lane item's (emitter: CmuxNextWakeups
    /// `LaneScheduler`) or a control request's on the main thread (``TaskTrace``, task 042). Ring:
    /// B/E. B arg0 the lane in bits 8-15 (0 files, 1 system, 2 cpu, 3 main, 0xFF a lane made without one) and the
    /// priority in bits 0-7 (a `WorkPriority`'s, or on the main lane a `MainWorkClass`'s, `rawValue`); B arg1 the
    /// queue wait in us (on the main lane `UInt64.max` when the post was not traced). Right after the B, the flow-in
    /// of a traced post (task 042): arg0 the post site, arg1 the flow id.
    case taskRun = 51

    // MARK: hang (reserved: PL-telemetry)
    /// Reserved (task 068, PL-telemetry). A watched thread past its hang-watch deadline. Ring: instant;
    /// arg0 the thread's name id, arg1 how far past the deadline, in ms.
    case hangThreadHung = 52
    /// Reserved (task 110, PL-telemetry). The main thread stalled for 2 s: the fatal-hang candidate is
    /// written to the crash-key page. Ring: instant; arg0 the stall's start (uptime ns).
    case hangInProgress = 53
    /// Reserved (task 067, PL-telemetry). A thread's open scopes invalidated before a nested run loop, a
    /// modal or a network or process wait. Ring: instant; arg0 the thread's name id.
    case hangInvalidated = 54

    // MARK: input (reserved: task 111, PL-typing)
    /// Reserved (task 111, PL-typing). An input event other than a key-down, from its `NSEvent` timestamp to
    /// the next content-changing commit (events that change no frame are dropped). Ring: AB/AE; begin arg0
    /// the kind (mouse_down, mouse_up, drag, scroll, ime_commit, paste).
    case inputFrame = 55
    /// One input event's EventLatency record (emitter `InputLatencyTracker` in CmuxNextInput, wired
    /// into the app's input dispatch by p04-input-005): a point event when its slot closes, at the presented estimate
    /// of the frame that shows it (the turn's commit for a view, the target's own content submission for a terminal
    /// or a page), so it never runs as an interval across turns. Message (``InputLatencySignpostMessage``, numbers
    /// only): `kind target entry source vrr coalesced frame gen_ns`, then each stage in microseconds after `gen_ns`, -1
    /// when skipped: `last_gen_us arrived_us dispatch_start_us ti_start_us ti_end_us dispatch_end_us commit_us
    /// content_us daemon_us pty_us echo_read_us echo_sent_us presented_us`. Ring: instant, "estimated" when the
    /// presented time is a vsync estimate (not when it was skipped); arg0 packs kind | target << 8 | entrypoint << 16
    /// | source << 24 | caused frame update << 32 | variable refresh << 33, arg1 the generated-to-presented time in us
    /// (0 when presented was skipped). Id 85: ids are append-only and 69-84 were taken first.
    case inputLatency = 85

    // MARK: webview (reserved: task 114, PL-telemetry)
    /// Reserved (task 114, PL-telemetry). A slow interaction in a cmux web page (`PerformanceObserver`
    /// 'event', over 16 ms). Ring: instant; arg0 the page index, arg1 the duration in us.
    case webviewINP = 56
    /// Reserved (task 114, PL-telemetry). A long animation frame (or a long task on WebKit) in a cmux web
    /// page. Ring: instant; arg0 the page index, arg1 the duration in us.
    case webviewLoAF = 57

    // MARK: remote (reserved: task 127, PL-telemetry)
    /// Reserved (task 127, PL-telemetry). An input event sent to the remote desktop. Ring: instant; arg0 its
    /// sequence number.
    case remoteInput = 58
    /// Reserved (task 127, PL-telemetry). A remote desktop frame decoded. Ring: instant; arg0 the frame number.
    case remoteFrameDecoded = 59
    /// Reserved (task 127, PL-telemetry). A remote desktop frame shown. Ring: instant; arg0 the frame number,
    /// arg1 the input sequence number it echoes, or 0.
    case remotePresent = 60

    // MARK: crash (reserved: PL-telemetry)
    /// Reserved (task 083, PL-telemetry). An abnormal Chromium helper exit. Ring: instant; arg0 the process
    /// type, arg1 the exit reason and code.
    case crashHelperExit = 61
    /// Reserved (task 108, PL-telemetry). A WebKit content process ended (`webViewWebContentProcessDidTerminate`).
    /// Ring: instant; arg0 the surface kind.
    case crashWebContentEnd = 62
    /// Reserved (task 108, PL-telemetry). A Chromium page unresponsive, from the shown state to its end.
    /// Ring: AB/AE.
    case crashRendererUnresponsive = 63
    /// Reserved (task 109, PL-telemetry). A child process exit the app saw (daemon, holder, host, acpmux,
    /// helpers). Ring: instant; arg0 the child kind, arg1 the exit (0 clean, 1 signal, 2 panic, 3 oom).
    case crashChildExit = 64
    /// Reserved (task 130, PL-telemetry). A Release invariant that reported without crashing. Ring: instant;
    /// arg0 the interned site.
    case crashDumpWithoutCrashing = 65

    // MARK: control (task 042; reserved: task 115, Performance Lead)
    /// Task 042 (`ControlRequestTrace`). One queued control request, from its enqueue on `MainActorWorkQueue` to
    /// the end of its run or its failure. Ring: AB/AE keyed by an async id (`TraceRuntime.nextAsyncScope`, in
    /// arg1 of both). AB arg0 the method's main task board owner index in bits 0-31 (0 without a board) and the
    /// main work class code (`MainWorkClass.rawValue + 1`) in bits 32-39. AE arg0 the outcome (0 ran, 1 expired
    /// while queued, 2 refused as busy: it never queued). Reserved (task 115): the accept-to-reply part and the
    /// parsed, queued and dispatched instants.
    case controlRequest = 66

    // MARK: ghostty (reserved: task 049, PL-ghostty)
    /// Task 049. One Ghostty `drawFrame` (`GhosttyTraceHook`). Ring: B/E; arg0 surface id, begin arg1 the echo's flow.
    case ghosttyRender = 67

    // MARK: resize (reserved: task 111, PL-motion-core)
    /// Reserved (task 111, PL-motion-core). One live window resize tick to the commit that shows it. Ring: AB/AE.
    case resizeFrame = 68

    // MARK: webui (p13-webui; the page trace id is the `PageWebView`'s address, so the four tracks join per page)
    /// Reserved (task 022, p13-webui). A page's lifecycle change (`PageLifecycle`). Ring: instant; arg0 the page
    /// trace id, arg1 the new state (0 active, 1 hidden, 2 frozen, 3 discarded).
    case webuiLifecycle = 69
    /// A page's open, from its request to its document's first painted frame (`PagePaintProbe`, either engine):
    /// a new view, a pooled spare's first load, a pool claim or retarget, a route loaded before the first load, a
    /// reload, or a document the page navigated to (from its commit). Ring: AB/AE keyed by the page trace id; begin
    /// arg0 bits 0-7 the kind (0 new view, 1 spare, 2 claim, 3 other document, 4 reload, 5 navigated), bits 8-63 a
    /// new view's construction time in microseconds before the begin; end arg0 the outcome (0 painted in WebKit,
    /// 1 painted in Chromium, 2 closed before its first paint, 3 replaced by a newer open of the same view).
    case webuiOpen = 70
    /// Reserved (task 043, p13-webui). A preload slot move (`PagePreloadSlot`). Ring: instant; arg0 the page trace
    /// id, arg1 the move (0 park, 1 claim, 2 drop).
    case webuiPreload = 71
    /// One main-thread step of a WebKit `cmux-page://` scheme task (`PageSchemeHandler`). Ring: B/E; begin arg0 the
    /// part (0 start, 1 answer, 2 a synchronous step of the reply), arg1 the asking page's trace id (0 for no page);
    /// end arg0 the outcome (0 ok, 1 failed), arg1 the answer's body bytes. The part-0 slices of a page id during its
    /// ``webuiOpen`` are that open's requests, and all its slices sum the handler's main-thread time for it.
    case webuiScheme = 72

    // MARK: stall, continued (emitter: CmuxNextWakeups `MainTurnMeter`)
    /// One busy main run-loop turn (the innermost nested loop's) ran past 4 ms. Ring only, no
    /// `os_signpost` (it is written on the main thread inside the slow turn, with no allocation):
    /// instant; arg0 the turn in us, bit 63 set for a nested turn; arg1 the scheduled tasks', render
    /// (before-waiting phase), input (`sendEvent`) and unattributed time, 16 bits each from bit 0, in
    /// 100 us units (0xFFFF at 6.5 s or more). Per turn: never mirrored to MetricKit.
    case stallMainTurn = 73

    // MARK: launch, continued (emitter: CmuxNextWakeups `StartupTaskLog`)
    /// One task the launch scheduler (`StartupScheduler`) runs, from its start to its return, on main or on
    /// its lane, and each first-frame launch start the launch turn calls directly (`LaunchStart.runNow`,
    /// priority `launchTurn`). Message: `name=<Domain.step> priority=<critical|afterFirstFrame|afterStartup|launchTurn>`.
    /// Ring: B/E (it begins and ends in one synchronous call on one thread); arg0 the priority's position + 1
    /// (0 not given, and for `launchTurn`). About a hundred per launch: never mirrored to MetricKit.
    case launchStartupTask = 75
    /// Startup completed (`StartupScheduler`'s completion, Chrome's `Startup.BrowserStartupCompleteReason`).
    /// Message: `reason=<reason>`. Ring: instant; arg0 the reason's position + 1, arg1 the afterStartup tasks
    /// held until then.
    case launchStartupComplete = 76

    // MARK: steps (emitters: the start-path timings)
    // Each step event fires every time its step happens, so none is in the launch category: the App keeps the
    // first of each as a launch mark (`launch.mark`), and the launch.* slices above end at those marks.

    /// One step of the app's daemon connection (`DaemonLaunchTimings`): the start path's login environment,
    /// `server ensure`, connect and handshake, and the steps that recur after it (a store resync's
    /// `daemon.snapshot_start` and `daemon.snapshot_end`, a terminal attach's `terminal.attach_start` and
    /// `terminal.attach_end`). Message: the step's fixed name. Ring: instant; arg0 the step's code
    /// (`DaemonLaunchTimings.Step`).
    case daemonStep = 77
    /// One step of an agent pane's page (`AgentPaneLaunchTimings`): painted, page loaded, handshake start and
    /// end, a new tab's paint and context. Message: the step's fixed name. Ring: instant; arg0 the step's code
    /// (`AgentPaneLaunchTimings.Step`).
    case webuiAgentPaneStep = 78
    /// One phase of the libghostty runtime's one-time start on main (`TerminalTimings`): `ghostty_init`, the
    /// config load, `ghostty_app_new`, then its first surface's (`TerminalFirstSurfaceSplit`). Message: `phase=<name>`. Ring: instant at the phase's end; arg0 the
    /// phase's code (`TerminalTimings.RuntimePhase`), arg1 its duration in ns.
    case stallGhosttyRuntimePhase = 79

    // MARK: launch reads (emitter: CmuxNextLaunch `LaunchReadEvent`)

    /// A launch read is done (CmuxNextLaunch `LaunchReadEvent.signal()`; Chromium's
    /// `base::OneShotEvent::Signal`): the steps that waited for it run next. Message: `read=<Domain.read>
    /// waiting=<steps released>`. Ring: instant; arg0 the steps released. Once per read per launch.
    case launchReadDone = 80

    // MARK: burst (emitter: CmuxNextControl `BurstTrace`)

    /// One burst bench mark (`BurstTrace`), in every build while the `burst` category records: a refusal the person
    /// saw, a Cmd-W's outcome, a grid sent to a PTY, its echo, the first output after it. Ring only: instant; arg0
    /// bits 0-7 the kind (`BurstTrace.Kind.traceCode`); a grid's cols in bits 8-23, rows in 24-39 and its echo due in
    /// bit 40; a close's tab count in bits 8-23 and pane emptied in bit 24. arg1 the PTY surface of a grid or an
    /// output, else the input event's `CLOCK_UPTIME_RAW` ns (0 without one).
    case burstEvent = 81

    // MARK: presentation (p03-rendering 004: what a Release build can say about frames it does not watch)
    /// A main-thread Core Animation commit, made while a Motion animation runs (`MotionActivity`), that ended past a
    /// deadline its run-loop turn could have met (`MotionLateCommits`): a display-link tick's turn, the tick's target
    /// timestamp; any other turn, one period past the first vsync after it began. The grid is the key window's
    /// display's last link tick; the counter starts no link and asks for no frame, so a commit with no recent tick
    /// is not judged. Message: `late_ms=<past the deadline> turn_ms=<turn start to commit end>`. Ring: instant;
    /// arg0 the lateness in us, arg1 the turn in us.
    case motionLateCommits = 82
    /// The estimated time an action's committed change is shown, recorded at its commit (`ActionBudgetMonitor`):
    /// the target timestamp of the first display-link tick after the commit, placed on the vsync grid of the
    /// key window's display's last tick (no link is started for it). Message: `id=<action id>
    /// present_ms=<run start to the estimate> commit_ms=<run start to the commit> input_age_ms=<age> phase=<running|
    /// recent|unknown>`, where `phase` says where the grid came from (a running link, a tick under a second old,
    /// none: then the estimate is the commit plus 1.5 refresh periods). Ring: instant with the "estimated" flag;
    /// arg0 the action's interned index in bits 0-31 and the phase code in bits 32-39, arg1 the estimate (uptime ns).
    case actionPresentedEstimate = 83
    /// Reserved (task 080, PL-ghostty). The measured time an action's change was shown (Ghostty's presentedTime),
    /// recorded next to ``actionPresentedEstimate`` where it exists. Ring: instant; arg0 the action's interned index,
    /// arg1 the presented time (uptime ns).
    case actionPresented = 84

    // MARK: cef memory pressure (emitter: CmuxNextBrowser `CEFMemoryPressureVote`)

    /// cmux's memory pressure vote into Chromium's aggregator (`cmux_shim_memory_pressure_vote`), the synchronous
    /// part of the call on the main thread: in process, the vote and the sync listeners Chromium runs when the
    /// aggregate changes; in host library mode, one post to the Chromium Host. Async listeners are not in it: in
    /// process they run in later `cef.pump` slices, in host mode in the host process. The memory coordinator's
    /// release slices run on later frames. Message: `level=<0 none|1 moderate|2 critical>`. Ring: B/E; begin arg0
    /// the level. Once per change of the coordinator's vote.
    case cefMemoryPressureVote = 86

    // MARK: ghostty lock wait (emitter: CmuxNextTerminal `GhosttyLockWaitSignpost`)

    /// One input entry point's wait of 50 us or more for Ghostty's terminal lock (key, modifier change, IME point,
    /// text, preedit, a manual surface's input write), reported by ghostty-next after the wait
    /// (`ghostty_surface_set_lock_wait_callback`).
    /// Debug and bench builds whose GhosttyNextKit has the report (`GHOSTTY_LOCK_WAIT`). Message:
    /// `wait_us=<wait>`. Ring: instant; arg0 the wait in ns.
    case ghosttyLockWait = 87

    // MARK: launch catalog read (emitter: CmuxNextActions `ActionCatalogLaunch`)

    /// The registry's first read of the action catalog on the main thread (`ActionCatalogLaunch.descriptors()`),
    /// from its start to its return: 0 when the launch warm-up thread had built the catalog, the rest of that build
    /// when it was still running, the whole build when main claimed it. Message: `outcome=<ready|waited|
    /// built_on_main>`. Ring: B/E; begin arg0 the outcome (`ActionCatalogMainAccess.Outcome`'s raw value). Once
    /// per launch.
    case launchActionCatalogFirstMainAccess = 88

    /// The name `os_signpost` records (a compile-time string, as the API requires).
    public var staticName: StaticString {
        switch self {
        case .actionPerform: "action.perform"
        case .actionCommit: "action.commit"
        case .actionGate: "action.gate"
        case .motionFrame: "motion.frame"
        case .motionRun: "motion.run"
        case .motionDragFrame: "motion.drag_frame"
        case .keyToFrame: "key.frame"
        case .keyFlow: "key.flow"
        case .scrollToFrame: "key.scroll_frame"
        case .keyOmnibarSuggest: "key.omnibar_suggest"
        case .keyPaletteSearch: "key.palette_search"
        case .keyEchoHostPTYRead: "key.echo.host_pty_read"
        case .keyEchoHostClientWrite: "key.echo.host_client_write"
        case .keyEchoDaemonFrames: "key.echo.daemon_frames"
        case .keyEchoSurfaceParse: "key.echo.surface_parse"
        case .keyEchoAttachEncode: "key.echo.attach_encode"
        case .keyEchoLineOut: "key.echo.line_out"
        case .keyEchoAppTransportRead: "key.echo.app_transport_read"
        case .keyEchoMainActor: "key.echo.main_actor"
        case .keyEchoOutputLane: "key.echo.output_lane"
        case .keyEchoRenderer: "key.echo.renderer"
        case .keyEchoGPUDone: "key.echo.gpu_done"
        case .keyEchoContents: "key.echo.contents"
        case .switchWorkspace: "switch.workspace"
        case .switchTab: "switch.tab"
        case .switchPaneFocus: "switch.pane_focus"
        case .switchAppActivation: "switch.app_activation"
        case .createTab: "create.tab"
        case .createWorkspace: "create.workspace"
        case .cefPump: "cef.pump"
        case .cefCreateBrowser: "cef.create_browser"
        case .cefGeometry: "cef.geometry"
        case .cefHostInput: "cef.host_input"
        case .launchProcessToMain: "launch.process_to_main"
        case .launchFirstWindow: "launch.first_window"
        case .launchFirstFrame: "launch.first_frame"
        case .launchDaemonReady: "launch.daemon_ready"
        case .launchFirstTerminalOutput: "launch.first_terminal_output"
        case .launchStartupTask: "launch.startup_task"
        case .launchStartupComplete: "launch.startup_complete"
        case .launchReadDone: "launch.read_done"
        case .stallMainTask: "stall.main_task"
        case .stallOverBudget: "stall.over_budget"
        case .stallMainTurn: "stall.main_turn"
        case .stallCreateSurface: "stall.create_surface"
        case .stallPaletteOpen: "stall.palette_open"
        case .stallIconPickerOpen: "stall.icon_picker_open"
        case .stallRenderStarved: "stall.render_starved"
        case .daemonRequest: "daemon.request"
        case .frameTick: "frame.tick"
        case .frameCommit: "frame.commit"
        case .frameGPUDone: "frame.gpu_done"
        case .framePresentEstimate: "frame.present_estimate"
        case .frameSequence: "frame.sequence"
        case .taskPost: "task.post"
        case .taskRun: "task.run"
        case .hangThreadHung: "hang.thread_hung"
        case .hangInProgress: "hang.in_progress"
        case .hangInvalidated: "hang.invalidated"
        case .inputFrame: "input.frame"
        case .inputLatency: "input.latency"
        case .webviewINP: "webview.inp"
        case .webviewLoAF: "webview.loaf"
        case .remoteInput: "remote.input"
        case .remoteFrameDecoded: "remote.frame_decoded"
        case .remotePresent: "remote.present"
        case .crashHelperExit: "crash.helper_exit"
        case .crashWebContentEnd: "crash.webkit_content_end"
        case .crashRendererUnresponsive: "crash.renderer_unresponsive"
        case .crashChildExit: "crash.child_exit"
        case .crashDumpWithoutCrashing: "crash.dump_without_crashing"
        case .controlRequest: "control.request"
        case .ghosttyRender: "ghostty.render"
        case .resizeFrame: "resize.frame"
        case .webuiLifecycle: "webui.lifecycle"
        case .webuiOpen: "webui.open"
        case .webuiPreload: "webui.preload"
        case .webuiScheme: "webui.scheme"
        case .daemonStep: "daemon.step"
        case .webuiAgentPaneStep: "webui.agent_pane_step"
        case .stallGhosttyRuntimePhase: "stall.ghostty_runtime_phase"
        case .burstEvent: "burst.event"
        case .motionLateCommits: "motion.late_commits"
        case .actionPresentedEstimate: "action.presented_estimate"
        case .actionPresented: "action.presented"
        case .cefMemoryPressureVote: "cef.memory_pressure_vote"
        case .ghosttyLockWait: "ghostty.lock_wait"

        case .launchActionCatalogFirstMainAccess: "launch.action_catalog_first_main_access"
        }
    }
}
