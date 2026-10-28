// The dimensions of the HistogramID families (plans/cmux-next/chrome-parity/p09-observability.md
// section 3D). Part of the frozen catalog (task 000; rule 2 of section 4 freezes this file with
// HistogramID.swift): a raw value is the last part of a histogram's name, and a name never changes
// meaning. Every case is a name, so each has a doc comment. Owner: PL-telemetry with each family's owner
// (HistogramID.owner).

extension HistogramID {
    /// What had the keyboard for `key.frame` (as `KeyFrameSignpost.Target`).
    public enum KeyTarget: String, Sendable, CaseIterable {
        /// A text view: the commit shows the typed character.
        case view
        /// A terminal: the commit shows the key's own work.
        case terminal
    }

    /// Where a terminal's echo came from for `key.echo_frame`.
    public enum EchoRoute: String, Sendable, CaseIterable {
        /// This Mac's daemon.
        case local
        /// A daemon on another machine through a bridge (SSH or a link).
        case bridge
        /// A cmux Cloud machine.
        case cloud
    }

    /// The input event kinds of `input.frame` (Chrome's `EventLatency.<type>`).
    public enum InputKind: String, Sendable, CaseIterable {
        /// A mouse button press.
        case mouseDown = "mouse_down"
        /// A mouse button release.
        case mouseUp = "mouse_up"
        /// A drag (one coalesced event per frame).
        case drag
        /// A scroll event (wheel, trackpad or momentum).
        case scroll
        /// An input-method commit.
        case imeCommit = "ime_commit"
        /// A paste.
        case paste
    }

    /// Main-thread congestion measured by execution time alone or by queue plus execution time (Chrome's
    /// responsiveness calculator, content/browser/scheduler/responsiveness/calculator.h).
    public enum CongestionKind: String, Sendable, CaseIterable {
        /// Execution time only.
        case exec
        /// Queue wait plus execution time.
        case queue
    }

    /// The startup stage a sample falls in.
    public enum StartupStage: String, Sendable, CaseIterable {
        /// Before the first window's first frame plus 30 s.
        case launch
        /// After it.
        case steady
    }

    /// The lanes `hang.thread_hung` names (the watched threads and lanes of section 3E in the app).
    public enum HangLane: String, Sendable, CaseIterable {
        /// The app's main thread.
        case main
        /// The daemon connection's socket reader.
        case daemonReader = "daemon_reader"
        /// The daemon connection's socket writer.
        case daemonWriter = "daemon_writer"
        /// The terminal output lane that feeds Ghostty.
        case terminalOutput = "terminal_output"
        /// A local PTY's reader and writer (no daemon in the path).
        case localPTY = "local_pty"
        /// A `BackgroundWork` lane.
        case backgroundWork = "background_work"
        /// The app control socket's handlers.
        case control
        /// The diagnostics lane (debug dumps, hang and crash report assembly).
        case diagnostics
        /// The remote desktop view's decode and present lane.
        case remoteView = "remote_view"
        /// The phone host's connection lane.
        case mobile
        /// The acpmux agent pane's connection lane.
        case acpmuxPane = "acpmux_pane"
        /// The acpmux status reader.
        case acpmuxStatus = "acpmux_status"
        /// The agent activity monitor.
        case agentActivity = "agent_activity"
        /// The browser host provider's connection lane.
        case browserHostProvider = "browser_host_provider"
        /// The watcher of Chromium's child processes.
        case cefChildren = "cef_children"
        /// A Ghostty renderer thread.
        case ghosttyRenderer = "ghostty_renderer"
        /// Chromium's IO thread in the app.
        case chromiumIO = "chromium_io"
        /// The out-of-process Chromium host's main thread.
        case chromiumHostMain = "chromium_host_main"
        /// A lane registered after this list was frozen.
        case other
    }

    /// Where an action run came from (the same cases as CmuxNextActions `ActionEntrypoint`).
    public enum Entrypoint: String, Sendable, CaseIterable {
        /// A person's key press.
        case key
        /// A person's click or drop.
        case pointer
        /// A person's run with no input event being dispatched (a gate's later run, a view's own callback).
        case unattributed
        /// The `cmux` CLI.
        case cli
        /// An MCP client.
        case mcp
        /// A script.
        case script
        /// Another client.
        case remote
        /// A first-party web page.
        case page
    }

    /// The three window and tab commands Chrome's speed bar watches.
    public enum Command: String, Sendable, CaseIterable {
        /// Cmd-T, a new tab.
        case cmdT = "cmd_t"
        /// Cmd-N, a new window.
        case cmdN = "cmd_n"
        /// Cmd-W, close a tab.
        case cmdW = "cmd_w"
    }

    /// The frame sequences `smoothness.dropped_pct` measures (Chrome's `FrameSequenceTracker` types).
    public enum FrameSequence: String, Sendable, CaseIterable {
        /// A layout motion (springs).
        case motion
        /// A scroll, momentum included.
        case scroll
        /// A live window resize.
        case resize
        /// A tab or pane drag.
        case drag
        /// The remote desktop view's stream.
        case remoteStream = "remote_stream"
    }

    /// The launch temperature from the page-in count (Chrome's startup_metric_utils), built from the launch's one
    /// classifier, `LaunchClock.Temperature` (``init(_:)``; an undetermined launch has none).
    public enum LaunchTemperature: String, Sendable, CaseIterable {
        /// Few page-ins: the app's pages were in memory.
        case warm
        /// Some page-ins.
        case lukewarm
        /// Most pages read from disk.
        case cold
    }

    /// The wakeup counters of `idle.wakeups`.
    public enum WakeupSource: String, Sendable, CaseIterable {
        /// The app's main thread.
        case appMain = "app_main"
        /// Every app thread.
        case appTotal = "app_total"
        /// The cmux-tui daemon.
        case daemon
    }

    /// The process kinds of the memory, CPU and child-exit families.
    public enum ProcessKind: String, Sendable, CaseIterable {
        /// The cmux app.
        case app
        /// The cmux-tui daemon.
        case daemon
        /// A terminal host (`cmux-tui-host`).
        case host
        /// The PTY holder (`cmux-holder`).
        case holder
        /// The acpmux daemon.
        case acpmux
        /// An acpmux agent host.
        case agentHost = "agent_host"
        /// `cmux-app-host`.
        case appHost = "app_host"
        /// `cmux-browser-host`.
        case browserHost = "browser_host"
        /// The out-of-process Chromium host.
        case chromiumHost = "chromium_host"
        /// A Chromium renderer.
        case renderer
        /// Chromium's GPU process.
        case gpu
        /// A Chromium utility process.
        case utility
        /// A WebKit content process.
        case webkit
    }

    /// The daemon's request classes (cmux-tui-core `MethodClass`, task 013).
    public enum MethodClass: String, Sendable, CaseIterable {
        /// Moves, splits, closes and focus changes of workspaces, panes and tabs.
        case topology
        /// Terminal input, output and resize.
        case terminalIO = "terminal_io"
        /// Creating a workspace, pane, tab or terminal.
        case create
        /// Reads that change nothing.
        case query
        /// Browser tab requests.
        case browser
        /// Agent and acpmux requests.
        case agent
        /// cmux Cloud and remote machine requests.
        case cloud
        /// A request no other class names.
        case other
    }

    /// The cmux web pages of the `webview` families: the first-party page ids (CmuxNextCompat
    /// `FirstPartyPages`) and Home, a static list so no page URL becomes a name.
    public enum Page: String, Sendable, CaseIterable {
        /// Home.
        case home
        /// The history page.
        case history
        /// The apps page.
        case apps
        /// Settings.
        case settings
        /// The cmux Cloud page.
        case cloud
        /// The agent pane.
        case agent
        /// The keyboard shortcuts page.
        case keybindings
        /// The diff viewer.
        case diff
        /// The Markdown viewer.
        case markdown
        /// The passwords page.
        case passwords
        /// The editor.
        case editor
        /// The changelog.
        case changelog
        /// The icon picker.
        case iconPicker = "icon_picker"
        /// The Chief inspector.
        case chiefInspector = "chief_inspector"
        /// Debug settings.
        case debugSettings = "debug_settings"
        /// Home's channel list.
        case homeChannels = "home_channels"
        /// A page added after this list was frozen.
        case other
    }

    /// How the app's last run ended when it did not quit cleanly (`stability.unclean_exit` values).
    public enum UncleanExit: Int64, Sendable, CaseIterable {
        /// The app crashed (a signal or an exception).
        case crash = 0
        /// The Mac shut down or restarted (a new boot session).
        case systemShutdown = 1
        /// Something else ended the process (SIGKILL, jetsam, Force Quit).
        case killed = 2
        /// The main thread was stalled when the process ended (task 110).
        case fatalHang = 3
    }

    /// How a child process ended (`stability.child_exit.<kind>` values).
    public enum ChildExit: Int64, Sendable, CaseIterable {
        /// Exit status 0.
        case clean = 0
        /// Ended by a signal.
        case signal = 1
        /// A Rust panic, or a fatal error the process reported.
        case panic = 2
        /// Killed for memory (jetsam).
        case oom = 3
    }

    /// The engines of the `stability.renderer` families: whose page process an event is about.
    public enum RendererEngine: String, Sendable, CaseIterable {
        /// A WebKit WebContent process.
        case webkit
        /// A Chromium renderer.
        case chromium
    }

    /// The renderer events of the `stability.renderer` families.
    public enum RendererEvent: String, Sendable, CaseIterable {
        /// The content process ended under a page (each page it served counts).
        case contentEnd = "content_end"
        /// A page started showing "Page unresponsive".
        case unresponsive
    }

    /// The kind of view that showed the page (`stability.renderer.<event>.<engine>` values).
    public enum RendererSurface: Int64, Sendable, CaseIterable {
        /// A browser tab.
        case browserTab = 0
        /// A cmux page (Home, Settings, the agent chat), in either engine.
        case page = 1
        /// The agent pages' WebKit warm-up page.
        case warmup = 2
    }

    /// The Chromium histograms read from `base::StatisticsRecorder` (task 107's allowlist), by Chromium's
    /// own names.
    public enum Chromium: String, Sendable, CaseIterable {
        /// A key press to its frame in a page.
        case keyPressedLatency = "EventLatency.KeyPressed.TotalLatency"
        /// A mouse press to its frame in a page.
        case mousePressedLatency = "EventLatency.MousePressed.TotalLatency"
        /// Dropped frames over every frame sequence.
        case droppedFrames = "Graphics.Smoothness.PercentDroppedFrames3.AllSequences"
        /// A renderer's private memory footprint.
        case rendererMemory = "Memory.Renderer.PrivateMemoryFootprint"
        /// The GPU process's private memory footprint.
        case gpuMemory = "Memory.Gpu.PrivateMemoryFootprint"
        /// Chromium's stability event counts.
        case stabilityCounts = "Stability.Counts2"
        /// A navigation to its first contentful paint.
        case firstContentfulPaint = "PageLoad.PaintTiming.NavigationToFirstContentfulPaint"
    }
}
