// The dimensions of the HistogramID families (plans/cmux-next/chrome-parity/p09-observability.md
// section 3D). Part of the frozen catalog (task 000): a raw value is the last part of a histogram's name,
// and a name never changes meaning. Owner: PL-telemetry with each family's owner (HistogramID.owner).

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
        case main
        case daemonReader = "daemon_reader"
        case daemonWriter = "daemon_writer"
        case terminalOutput = "terminal_output"
        case localPTY = "local_pty"
        case backgroundWork = "background_work"
        case control
        case diagnostics
        case remoteView = "remote_view"
        case mobile
        case acpmuxPane = "acpmux_pane"
        case acpmuxStatus = "acpmux_status"
        case agentActivity = "agent_activity"
        case browserHostProvider = "browser_host_provider"
        case cefChildren = "cef_children"
        case ghosttyRenderer = "ghostty_renderer"
        case chromiumIO = "chromium_io"
        case chromiumHostMain = "chromium_host_main"
        /// A lane registered after this list was frozen.
        case other
    }

    /// Where an action run came from (the same cases as CmuxNextActions `ActionEntrypoint`).
    public enum Entrypoint: String, Sendable, CaseIterable {
        case key, pointer, unattributed, cli, mcp, script, remote, page
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
        case motion, scroll, resize, drag
        /// The remote desktop view's stream.
        case remoteStream = "remote_stream"
    }

    /// The launch temperature from the page-in count (Chrome's startup_metric_utils).
    public enum LaunchTemperature: String, Sendable, CaseIterable {
        case warm, lukewarm, cold
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
        case app, daemon, host, holder, acpmux
        case agentHost = "agent_host"
        case appHost = "app_host"
        case browserHost = "browser_host"
        case chromiumHost = "chromium_host"
        case renderer, gpu, utility, webkit
    }

    /// The daemon's request classes (cmux-tui-core `MethodClass`, task 013).
    public enum MethodClass: String, Sendable, CaseIterable {
        case topology
        case terminalIO = "terminal_io"
        case create, query, browser, agent, cloud, other
    }

    /// The cmux web pages of the `webview` families: the first-party page ids (CmuxNextCompat
    /// `FirstPartyPages`) and Home, a static list so no page URL becomes a name.
    public enum Page: String, Sendable, CaseIterable {
        case home, history, apps, settings, cloud, agent, keybindings, diff, markdown, passwords, editor, changelog
        case iconPicker = "icon_picker"
        case chiefInspector = "chief_inspector"
        case debugSettings = "debug_settings"
        case homeChannels = "home_channels"
        /// A page added after this list was frozen.
        case other
    }

    /// How the app's last run ended when it did not quit cleanly (`stability.unclean_exit` values).
    public enum UncleanExit: Int64, Sendable, CaseIterable {
        case crash = 0
        /// The Mac shut down or restarted (a new boot session).
        case systemShutdown = 1
        case killed = 2
        /// The main thread was stalled when the process ended (task 110).
        case fatalHang = 3
    }

    /// How a child process ended (`stability.child_exit.<kind>` values).
    public enum ChildExit: Int64, Sendable, CaseIterable {
        case clean = 0, signal = 1, panic = 2, oom = 3
    }

    /// The Chromium histograms read from `base::StatisticsRecorder` (task 107's allowlist), by Chromium's
    /// own names.
    public enum Chromium: String, Sendable, CaseIterable {
        case keyPressedLatency = "EventLatency.KeyPressed.TotalLatency"
        case mousePressedLatency = "EventLatency.MousePressed.TotalLatency"
        case droppedFrames = "Graphics.Smoothness.PercentDroppedFrames3.AllSequences"
        case rendererMemory = "Memory.Renderer.PrivateMemoryFootprint"
        case gpuMemory = "Memory.Gpu.PrivateMemoryFootprint"
        case stabilityCounts = "Stability.Counts2"
        case firstContentfulPaint = "PageLoad.PaintTiming.NavigationToFirstContentfulPaint"
    }
}
