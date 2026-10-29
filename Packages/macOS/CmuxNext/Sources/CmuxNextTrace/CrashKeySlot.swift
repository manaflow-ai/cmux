/// One fixed slot of the app's crash-key page: a 4 KiB page of 64-bit words, written with relaxed
/// stores while the app runs and read from the file after a crash or a fatal hang (``CrashKeyPage``, task 078;
/// task 079 reads it at the next launch).
///
/// Chrome's crash keys (components/crash/core/common/crash_key.h) are static-storage name and value
/// pairs that the out-of-process handler reads from the dead process; setting one is a store, not an
/// allocation. cmux keeps the same rule with numbers only: every value is an id, a count, a state or a
/// time, never a person's text, so the page can go into a crash report as it is.
///
/// The raw value is the slot's first word in the page. Fixed and append-only: a page written by an older
/// build decodes. Words 0-7 are the page header (magic, version, pid, build, process start). Owner:
/// PL-telemetry.
public nonisolated enum CrashKeySlot: UInt16, Sendable, CaseIterable {
    /// The running action's id as a stable key (FNV-1a 64 of its raw value, `CrashKeySlots.stableKey`: the same
    /// number in every build and launch, so a report maps it back to the catalog), or 0 (set around
    /// `ActionRegistry` runs by `SignpostActionRunTiming`).
    case actionIndex = 8
    /// The running action's entrypoint (`ActionEntrypoint`'s trace position + 1), or 0.
    case actionEntrypoint = 9
    /// The owner of the main-thread task that runs now (`MainTaskBoard`) as a stable key (FNV-1a 64 of the owner
    /// name), or 0 between tasks.
    case mainTaskOwner = 10
    /// 1 while the Chromium message pump runs on this process's main thread (task 077).
    case inCEFPump = 11
    /// The uptime (ns) of the last input event the app dispatched.
    case lastInputUptime = 12
    /// The number of open windows.
    case windowCount = 13
    /// The number of workspaces in the local daemon's tree.
    case workspaceCount = 14
    /// The number of live terminal surfaces.
    case terminalCount = 15
    /// The number of live Chromium browser tabs.
    case chromiumBrowserCount = 16
    /// The number of live WebKit browser pages.
    case webKitViewCount = 17
    /// The local daemon's pid, or 0 while no daemon is connected.
    case daemonPID = 18
    /// The local daemon connection's state (0 none, 1 connecting, 2 ready, 3 reconnecting, 4 failed).
    case daemonState = 19
    /// The cmux CEF fork's API version the app runs (`cmux_shim_fork_api_version`), set once Chromium is ready.
    case cefAPIVersion = 20
    /// The first 8 bytes of the Ghostty commit the local daemon reports (`identify`), as a number; the bundled
    /// daemon and the app build from the same Ghostty submodule commit.
    case ghosttyCommit = 21
    /// While the main thread is stalled past 2 s: the stall's start (uptime ns); 0 otherwise (task 110).
    case hangInProgressStart = 22
    /// The number of frames in ``hangInProgressFrames`` (at most 64).
    case hangInProgressFrameCount = 23
    /// 32 words: up to 16 image UUIDs (2 words each) that the hang frames point into.
    case hangInProgressImages = 24
    /// 64 words: the stalled main thread's frames, innermost first; each is the image's index in
    /// ``hangInProgressImages`` (high 16 bits) and the offset in that image (low 48 bits).
    case hangInProgressFrames = 56
    /// The maker of the last agent pane freed without its `close()` and when (``unclosedAgentPane(maker:uptimeNanos:)``;
    /// 0: none), set as it is freed: an abort in that pane's teardown names its owner (2026-10-28,
    /// handoff/cef-parent-tracker-crash.md). One word after ``hangInProgressFrames``' 64.
    case unclosedAgentPaneMaker = 120

    /// The number of 64-bit words the slot holds.
    public var wordCount: Int {
        switch self {
        case .hangInProgressImages: 32
        case .hangInProgressFrames: 64
        default: 1
        }
    }

    /// The slot's name in a crash report's tags (`crash_key.<name>`).
    public var name: StaticString {
        switch self {
        case .actionIndex: "action_index"
        case .actionEntrypoint: "action_entrypoint"
        case .mainTaskOwner: "main_task_owner"
        case .inCEFPump: "in_cef_pump"
        case .lastInputUptime: "last_input_uptime"
        case .windowCount: "window_count"
        case .workspaceCount: "workspace_count"
        case .terminalCount: "terminal_count"
        case .chromiumBrowserCount: "chromium_browser_count"
        case .webKitViewCount: "webkit_view_count"
        case .daemonPID: "daemon_pid"
        case .daemonState: "daemon_state"
        case .cefAPIVersion: "cef_api_version"
        case .ghosttyCommit: "ghostty_commit"
        case .hangInProgressStart: "hang_in_progress_start"
        case .hangInProgressFrameCount: "hang_in_progress_frame_count"
        case .hangInProgressImages: "hang_in_progress_images"
        case .hangInProgressFrames: "hang_in_progress_frames"
        case .unclosedAgentPaneMaker: "unclosed_agent_pane_maker"
        }
    }

    /// The page's size in 64-bit words (4 KiB).
    public static let pageWordCount = 512
    /// The words at the start of the page that hold its header, before the first slot.
    public static let headerWordCount = 8
}

extension CrashKeySlot {
    /// ``unclosedAgentPaneMaker``'s word for a pane of maker `code` (`AgentPaneMaker`'s raw value) freed without its
    /// `close()` at `uptimeNanos` (`CLOCK_UPTIME_RAW`): the code in the high 8 bits, the uptime in the low 56 (2.2 years
    /// of nanoseconds). A crash long after the free shows the gap, so it is not taken for that pane's teardown.
    public static func unclosedAgentPane(maker code: UInt8, uptimeNanos: UInt64) -> UInt64 {
        UInt64(code) << 56 | (uptimeNanos & unclosedAgentPaneUptimeMask)
    }

    /// The maker code and the free's uptime in nanoseconds of an ``unclosedAgentPaneMaker`` word.
    public static func unclosedAgentPane(_ word: UInt64) -> (maker: UInt8, uptimeNanos: UInt64) {
        (UInt8(truncatingIfNeeded: word >> 56), word & unclosedAgentPaneUptimeMask)
    }

    static var unclosedAgentPaneUptimeMask: UInt64 { (1 << 56) - 1 }
}
