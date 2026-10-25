import AppKit
import class CmuxNextAgentPane.AgentPaneLaunchTimings
import CmuxNextDesign
import CmuxNextPalette
import CmuxNextSettings
import CmuxNextTerminal
import CmuxNextUpdater
import class CmuxNextDaemon.DaemonLaunchTimings
import Darwin
import os
import CmuxNextCompat

/// `debug.timings`: main-thread spans of the paths the stall bench measures
/// (scripts/cmux-next/bench-stalls.py): launch phases, each palette and icon
/// picker open, each terminal surface creation. `clear` drops the per-event lists (the
/// launch marks stay). Each span is also an Instruments signpost interval
/// (subsystem com.cmuxterm.app.next, category "stalls").
@MainActor
enum DebugTimings {
    static let signposter = OSSignposter(subsystem: "com.cmuxterm.app.next", category: "stalls")

    /// Launch marks from any thread (the daemon start path runs off main).
    private nonisolated static let launchMarks = Mutex<[(name: String, ms: Double)]>([])
    private static var paletteOpens: [PaletteOpenTiming] = []
    private static var iconPickerOpens: [IconPickerOpenTiming] = []
    private static var surfaces: [Double] = []
    /// Main-actor time of each Chats feed drain (`ChatsFeed.apply`, observers included) and
    /// each turn-state drain (`AgentTurnStateFeed`): cx-9c8m.6 measures the per-change cost.
    private static var chatsFeedApplies: [(lines: Int, ms: Double)] = []
    private static var turnStateApplies: [(lines: Int, ms: Double)] = []
    /// Main-actor time of each control snapshot publish and its tab count (cx-1ox9m).
    private static var controlPublishes: [(tabs: Int, ms: Double)] = []
    /// Each omnibar focusing click (`debug.omnibar_bench`): the mouse-down's age when the field
    /// took focus, and mouse-down to the committed frame that shows the editing look.
    private static var omnibarClicks: [(engine: String, input: Double, keyToFrame: Double)] = []
    private static let capacity = 256

    private static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }

    private nonisolated static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }()

    /// The marks of a pane's first frame of its own live content, not a saved picture: the
    /// terminal's first frame after the daemon's content reached its surface (`LaunchSettle`),
    /// the agent page's (or its New Tab page's) first paint. The first of them is also `first_live_content_frame`,
    /// Chrome's `RecordFirstWebContentsNonEmptyPaint`
    /// (components/startup_metric_utils/browser/startup_metric_utils.h).
    private nonisolated static let liveContentFrameMarks: Set<String> = ["first_terminal_frame", "agent_pane.painted", "agent_pane.newtab_painted"]

    /// Records a launch mark (milliseconds since process start) once per
    /// name, from any thread.
    nonisolated static func markLaunch(_ name: String, at date: Date = Date()) {
        _ = recordLaunchMark(name, at: date)
    }

    /// Records `name` unless it was already; true when this call recorded it.
    private nonisolated static func recordLaunchMark(_ name: String, at date: Date) -> Bool {
        let ms = date.timeIntervalSince(processStart) * 1_000
        let first = launchMarks.withLock { marks in
            guard !marks.contains(where: { $0.name == name }) else { return false }
            marks.append((name, ms))
            return true
        }
        guard first else { return false }
        LaunchMarkSink.shared.write(name: name, ms: ms)
        #if DEBUG || CMUX_BENCH_HOOKS
        UpdateHarness.mark("launch.\(name)", at: date)
        #endif
        if liveContentFrameMarks.contains(name) { markLaunch("first_live_content_frame", at: date) }
        return true
    }

    /// Marks `run_loop_start` at the main run loop's first entry, Chrome's
    /// `RecordBrowserMainMessageLoopStart`: a one-shot entry observer, which the run loop
    /// removes after its one call. Call it in `main()` just before `NSApp.run()`.
    static func armRunLoopStartMark() {
        MainRunLoopObserver.once(activities: .entry, order: CFIndex.min) { markLaunch("run_loop_start") }
    }

    /// Marks `first_idle` the first time the main run loop is about to sleep after
    /// `applicationDidFinishLaunching`, Chrome's `RecordBrowserMainLoopFirstIdle`: a one-shot
    /// before-waiting observer ordered after AppKit's display and the Core Animation commit,
    /// so the turn it closes is the whole launch turn. Call it at the end of that method.
    static func armFirstIdleMark() {
        MainRunLoopObserver.once(activities: .beforeWaiting, order: CFIndex.max) { markLaunch("first_idle") }
    }

    /// The startup scheduler's completion (`StartupScheduler`: its refs reached zero or its
    /// failsafe fired): marks `startup_complete`, Chrome's `Startup.StartupComplete`, and with
    /// the first one only, `startup_complete.<reason>` at the same time, so `debug.timings` and
    /// the bench say why (Chrome's `Startup.BrowserStartupCompleteReason`).
    static func markStartupComplete(reason: String) {
        let now = Date()
        guard recordLaunchMark("startup_complete", at: now) else { return }
        markLaunch("startup_complete.\(reason)", at: now)
    }

    static func install() {
        DaemonLaunchTimings.shared.install { markLaunch($0, at: $1) }
        AgentPaneLaunchTimings.shared.install { markLaunch($0) }
        TerminalTimings.onSurfaceCreated = { duration in
            let ms = milliseconds(duration)
            if surfaces.count < capacity { surfaces.append(ms) }
            markLaunch("first_terminal_surface_created")
        }
    }

    /// Marks `reveal.<region>` when each launch region shows (its data
    /// landed, or the reveal deadline passed).
    static func markReveal(_ reveal: LaunchReveal) {
        for region in LaunchRegion.allCases {
            reveal.whenReady(region) { markLaunch("reveal.\(region.rawValue)") }
        }
    }

    static func palettePresented(_ timing: PaletteOpenTiming) {
        if paletteOpens.count < capacity { paletteOpens.append(timing) }
    }

    static func iconPickerOpened(_ timing: IconPickerOpenTiming) {
        if iconPickerOpens.count < capacity { iconPickerOpens.append(timing) }
    }

    static func chatsFeedApplied(lines: Int, _ duration: Duration) {
        if chatsFeedApplies.count < capacity { chatsFeedApplies.append((lines, milliseconds(duration))) }
    }

    static func turnStatesApplied(lines: Int, _ duration: Duration) {
        if turnStateApplies.count < capacity { turnStateApplies.append((lines, milliseconds(duration))) }
    }

    static func controlPublished(tabs: @autoclosure () -> Int, _ duration: Duration) {
        if controlPublishes.count < capacity { controlPublishes.append((tabs(), milliseconds(duration))) }
    }

    static func omnibarClicked(engine: String, input: Double, keyToFrame: Double) {
        if omnibarClicks.count < capacity { omnibarClicks.append((engine, input, keyToFrame)) }
    }

    static func handle(_ params: [String: JSONValue]) -> JSONValue {
        let report = self.report
        if params["clear"]?.boolValue == true {
            paletteOpens.removeAll()
            iconPickerOpens.removeAll()
            surfaces.removeAll()
            chatsFeedApplies.removeAll()
            turnStateApplies.removeAll()
            controlPublishes.removeAll()
            omnibarClicks.removeAll()
        }
        return report
    }

    private static var report: JSONValue {
        func round(_ ms: Double) -> JSONValue { .number((ms * 10).rounded() / 10) }
        var launch: [String: JSONValue] = [:]
        for mark in launchMarks.withLock({ $0 }) { launch[mark.name] = round(mark.ms) }
        return [
            "launch_ms_since_process_start": .object(launch),
            "palette_opens": .array(paletteOpens.map { open in
                ["ms": round(milliseconds(open.total)), "input_ms": round(milliseconds(open.input)),
                 "key_to_frame_ms": round(milliseconds(open.keyToFrame)), "model_ms": round(milliseconds(open.model)),
                 "panel_ms": round(milliseconds(open.panel)), "present_ms": round(milliseconds(open.present)),
                 "commit_ms": round(milliseconds(open.commit)), "created_panel": .bool(open.createdPanel)]
            }),
            "icon_picker_opens": .array(iconPickerOpens.map { open in
                ["ms": round(milliseconds(open.total)), "catalog_ms": round(milliseconds(open.catalog)),
                 "page_ms": round(milliseconds(open.page)), "present_ms": round(milliseconds(open.present)),
                 "created_page": .bool(open.createdPage)]
            }),
            "omnibar_clicks": .array(omnibarClicks.map {
                ["engine": .string($0.engine), "input_ms": round($0.input), "key_to_frame_ms": round($0.keyToFrame)]
            }),
            "terminal_surfaces_ms": .array(surfaces.map(round)),
            "chats_feed_applies": .array(chatsFeedApplies.map { ["lines": .number(Double($0.lines)), "ms": .number(($0.ms * 1000).rounded() / 1000)] }),
            "turn_state_applies": .array(turnStateApplies.map { ["lines": .number(Double($0.lines)), "ms": .number(($0.ms * 1000).rounded() / 1000)] }),
            "control_publishes": .array(controlPublishes.map { ["tabs": .number(Double($0.tabs)), "ms": .number(($0.ms * 1000).rounded() / 1000)] }),
            "ghostty_runtime_ms": .object(Dictionary(TerminalTimings.runtimePhases.map { ($0.name, round(milliseconds($0.duration))) },
                                                     uniquingKeysWith: { first, _ in first })),
        ]
    }
}
