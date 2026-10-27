/// The fixed signpost categories of the cmux app (subsystem ``SignpostCategory/subsystem``).
///
/// A category groups the intervals of one kind of user-visible work, so a bench or an
/// Instruments session can record one path (`log stream --signpost --predicate 'category ==
/// "action"'`). The raw values are stable: benches, Instruments templates and PL-telemetry's
/// opt-in hang reports match on them.
///
/// Each category is also one bit of the Release trace ring's category flags (``traceBit``; Chrome's
/// per-category `category_group_enabled` flag, base/trace_event/builtin_categories.h). The black box
/// records the ``isBlackBoxDefault`` categories from launch; a `trace.start` recording adds the others
/// (plans/cmux-next/chrome-parity/p09-observability.md section 3A). Owners of the list: PL-arch and
/// PL-telemetry. The bits are the table in plans/cmux-next/trace.md ("Category bits"), which the Swift,
/// Rust (`cmux_trace::category`) and C writers follow; a new category takes the next free bit there first.
public nonisolated enum SignpostCategory: String, Sendable, CaseIterable {
    /// Keyboard, menu, palette, context-menu and CLI actions (`ActionRegistry`).
    case action
    /// Layout motion: spring frames, live resize.
    case motion
    /// A key press to the frame that shows it (terminal, Home composer, omnibar).
    case key
    /// Workspace, tab, space and window switches.
    case `switch`
    /// Creating a workspace, pane or tab (terminal, Chromium, WebKit, chat, page).
    case create
    /// Chromium work on the main thread: message pump passes, browser window creation.
    case cef
    /// Launch phases.
    case launch
    /// Main-thread spans the stall bench measures (palette open, surface creation).
    case stall
    /// Burst bench events (`BurstSignposts` in CmuxNextControl, scripts/cmux-next/burst-bench.py): a
    /// refusal the person saw, a grid sent to a PTY, that terminal's first output after it. Events,
    /// not intervals; the bench times each against the press before it.
    case burst
    /// The app's requests to the cmux-tui daemon, from the send to the reply, and the steps of its connection
    /// (`daemon.step`). Owner: PL-daemon.
    case daemon
    /// Display frames: ticks, Core Animation commits, GPU completion, the estimated present and frame
    /// sequences. Owner: PL-motion-core.
    case frame
    /// Work items from their post to their run (BackgroundWork, LaneScheduler, MainActorWorkQueue and
    /// detached tasks), linked by a flow like Chrome's `TaskAnnotator`. Owner: Performance Lead.
    case task
    /// Hang watch: a watched thread past its deadline, a fatal-hang candidate, an invalidated scope.
    /// Owner: PL-telemetry.
    case hang
    /// Input events other than a key-down (mouse, drag, scroll, IME commit, paste) to the frame that
    /// shows them, like Chrome's `EventLatency`. Owner: PL-typing.
    case input
    /// The responsiveness of cmux's own web pages: slow interactions and long animation frames.
    /// Owner: PL-telemetry.
    case webview
    /// The remote desktop view: input sent, frame decoded, frame shown. Owner: PL-telemetry.
    case remote
    /// Child-process ends and soft invariant reports: Chromium helper exits, WebKit content-process
    /// ends, unresponsive renderers, dump-without-crashing sites. Owner: PL-telemetry.
    case crash
    /// The app's control socket: requests from the CLI, MCP and agents, from the accept to the reply.
    /// Owner: Performance Lead.
    case control
    /// Ghostty's renderer threads, through the ghostty-next trace hook. Owner: PL-ghostty.
    case ghostty
    /// Live window resize ticks to the frame that shows them. Owner: PL-motion-core.
    case resize
    /// cmux's own web pages (the WebUI host): lifecycle changes, opens to first paint, preload slot moves,
    /// `cmux-page://` scheme work and the agent pane page's steps. Owner: p13-webui.
    case webui
    /// The `tracing` and `log` crate events of the Rust daemons (acpmux's `trace_layer.rs`), one instant per
    /// event, like Chrome's log messages in the trace (`base/logging.cc`). Swift writes none. Owner: p09-observability.
    case log

    /// The unified-log subsystem every cmux signpost uses.
    public static let subsystem = "com.cmuxterm.app.next"

    /// This category's bit (0-63) in the trace ring's category flags (trace.md "Category bits"). A bit never
    /// changes or moves to another category: rings written by an older build decode with the same bits.
    /// The black-box defaults hold bits 0-8. Inlinable, so a disabled trace point folds it to a constant.
    @inlinable public var traceBit: UInt8 {
        switch self {
        case .action: 0
        case .key: 1
        case .switch: 2
        case .create: 3
        case .cef: 4
        case .launch: 5
        case .daemon: 6
        case .hang: 7
        case .crash: 8
        case .motion: 9
        case .frame: 10
        case .stall: 11
        case .task: 12
        case .burst: 13
        case .input: 14
        case .webview: 15
        case .remote: 16
        case .control: 17
        case .ghostty: 18
        case .resize: 19
        case .webui: 20
        case .log: 21
        }
    }

    /// Whether the always-on black box records this category from launch (section 3A: action, key,
    /// switch, create, cef, launch, daemon, hang, crash). The others fire per frame, per job or per
    /// event, so only a `trace.start` recording turns them on.
    public var isBlackBoxDefault: Bool {
        switch self {
        case .action, .key, .switch, .create, .cef, .launch, .daemon, .hang, .crash: true
        case .motion, .stall, .burst, .frame, .task, .input, .webview, .remote, .control, .ghostty, .resize,
             .webui, .log:
            false
        }
    }
}
