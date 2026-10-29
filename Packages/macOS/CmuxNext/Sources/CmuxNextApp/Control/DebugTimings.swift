import AppKit
import class CmuxNextAgentPane.AgentPaneLaunchTimings
import CmuxNextControl
import protocol CmuxNextAgentPane.PaneFirstPaintGated
import CmuxNextDesign
import CmuxNextLaunch
import CmuxNextPalette
import CmuxNextSettings
import CmuxNextSignposts
import CmuxNextTerminal
import CmuxNextTrace
import CmuxNextUpdater
import CmuxNextWakeups
import class CmuxNextDaemon.DaemonLaunchTimings
import Darwin
import CmuxNextCompat

/// `debug.timings`: main-thread spans of the paths the stall bench measures
/// (scripts/cmux-next/bench-stalls.py): launch phases, each palette and icon
/// picker open, each terminal surface creation. `clear` drops the per-event lists (the
/// launch marks stay). In every build, recording or not, each open's main-thread work is also a catalog
/// thread slice of category `stall`: `stall.palette_open` (`PaletteController`) and `stall.icon_picker_open`
/// (`IconPickerService`), in the trace ring and as os_signpost intervals.
@MainActor
enum DebugTimings {
    /// Launch marks from any thread (the daemon start path runs off main), the startup trace they go
    /// to when the launch asked for one (`CMUX_TRACE_STARTUP`), and the `launch.*` slices they end.
    private nonisolated static let launchMarks = Mutex<(marks: LaunchMarks, slices: LaunchSlices)>(
        (LaunchMarks(), LaunchSlices(processStartNanos: processStart.uptimeNanos)))
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

    /// The process start and the page-ins every launch mark reads (the system's).
    private nonisolated static let launchClock = LaunchClock()
    /// When the kernel started this process (PROC_PIDTBSDINFO), on the wall clock and the trace clock; now
    /// when the kernel does not answer. The launch's one clock pairing: every mark's date reaches the trace
    /// clock through it (``LaunchMarks/uptimeNanos(of:pairedWith:)``).
    private nonisolated static let processStart: LaunchClock.Instant = launchClock.processStart() ?? launchClock.now()
    private nonisolated static let processStartDate = Date(timeIntervalSince1970: Double(processStart.wallNanos) / 1e9)
    /// ``processStart`` on the trace clock (`CLOCK_UPTIME_RAW` nanoseconds), the zero of `debug.startup`'s task times.
    nonisolated static var processStartUptimeNanos: UInt64 { processStart.uptimeNanos }
    /// The page-ins and main-thread CPU read at the first frame, sent as values apart from the
    /// time marks. The temperature is ``LaunchSlices``'s (``launchMarks``).
    private nonisolated static let launchCounters = LaunchCounterLog(sink: LaunchMarkSink.shared)

    /// Milliseconds since the process started, on the launch marks' clock.
    nonisolated static func millisecondsSinceProcessStart(at date: Date = Date()) -> Double {
        date.timeIntervalSince(processStartDate) * 1_000
    }

    /// Records a launch mark (milliseconds since process start) once per
    /// name, from any thread. The first record of a name goes to
    /// ``LaunchMarkSink``: a launch os_signpost in every build, and the
    /// bench's pipe when one was passed; and to the startup trace when one is attached. A milestone mark
    /// ends its `launch.*` slice; ``LaunchSlices/temperatureMark`` reads the page-ins first (Chrome reads them
    /// before its message-loop start's own work), writes the slices that waited, records `launch.pageins`, and
    /// sends the bench `launch.temperature.<name>` and `launch.pageins_run_loop_start`.
    /// A first live content frame (``LaunchMarks/liveContentFrameMarks``) also marks `first_live_content_frame`, once.
    nonisolated static func markLaunch(_ name: String, at date: Date = Date()) {
        // First, so the mark's own work never reaches the counters.
        launchCounters.read(atMilestone: name)
        let reading = LaunchSlices.Reading(mark: name, clock: launchClock)
        let endNanos = reading.milestone == nil ? 0 : LaunchMarks.uptimeNanos(of: date, pairedWith: processStart)
        let (ms, trace, step) = launchMarks.withLock { state -> (Double?, StartupTrace?, LaunchSlices.Step) in
            guard let ms = state.marks.record(name, at: date, processStart: processStartDate) else {
                return (nil, state.marks.trace, LaunchSlices.Step())
            }
            return (ms, state.marks.trace, state.slices.apply(reading, atUptimeNanos: endNanos))
        }
        guard let ms else { return }
        step.publish(into: .shared)
        LaunchMarkSink.shared.write(name: name, ms: ms)
        LaunchMarks.forward(name, at: date, to: trace, pairedWith: processStart)
        #if DEBUG || CMUX_BENCH_HOOKS
        UpdateHarness.mark("launch.\(name)", at: date)
        #endif
        if let pageins = step.pageins {
            LaunchMarkSink.shared.writeValue(name: LaunchSlices.pageinsValueMark, value: pageins)
        }
        if let temperatureInstant = step.temperatureInstant { markLaunch(temperatureInstant, at: date) }
        if let derived = LaunchMarks.derivedMark(of: name) { markLaunch(derived, at: date) }
    }

    /// The launch marks so far (`debug.startup`).
    nonisolated static var launchMarksNow: LaunchMarks { launchMarks.withLock { $0.marks } }

    /// The startup trace `CMUX_TRACE_STARTUP` asks for, attached before the first mark (`main`).
    nonisolated static func makeStartupTrace() -> StartupTrace? {
        guard let trace = StartupTrace.fromEnvironment(processStartNanos: processStart.uptimeNanos) else { return nil }
        launchMarks.withLock { $0.marks.attach(trace, processStart: processStart) }
        return trace
    }

    /// Marks `first_page_frame` when `view`, a page just put in a pane (an agent page or an
    /// internal page, ``PaneFirstPaintGated``), first paints while its tab's visibility `node` is
    /// visible. A page that paints out of sight (the New Tab spare parked in its window, a pane of
    /// a hidden window) is not live content; Chrome's `FirstWebContentsProfiler` likewise stops
    /// at a hidden or background tab (chrome/browser/metrics/first_web_contents_profiler.cc).
    static func markFirstPageFrame(of view: NSView?, node: VisibilityNode) {
        let pageFrame = "first_page_frame"
        guard let gated = view as? any PaneFirstPaintGated, !launchMarks.withLock({ $0.marks.contains(pageFrame) }) else { return }
        gated.whenFirstPainted { [weak node] in
            guard node?.isVisible == true else { return }
            markLaunch(pageFrame)
        }
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
    /// so the turn it closes is the whole launch turn. Call it at `did_finish_launching_end`.
    static func armFirstIdleMark() {
        MainRunLoopObserver.once(activities: .beforeWaiting, order: CFIndex.max) { markLaunch("first_idle") }
    }

    /// - Parameters:
    ///   - watchdog: Sends main-thread turns over 1 ms to `startupTrace` until it closes.
    ///   - startupTrace: The launch's startup trace (``makeStartupTrace()``), or nil.
    static func install(watchdog: MainThreadWatchdog, startupTrace: StartupTrace?) {
        #if DEBUG
        DebugWindowRecord.watchLaunch()
        #endif
        if let startupTrace {
            watchdog.setMainTurnSink(minimumNanos: StartupTrace.mainTurnThresholdNanos) { startupTrace.mainTurn(start: $0, end: $1) }
            // Closed, the trace takes nothing more: the sink comes off and a main turn is one relaxed load again.
            startupTrace.whenClosed { watchdog.setMainTurnSink(minimumNanos: 0, nil) }
        }
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

    /// - Parameter launchValues: The app's numeric launch values (`AppServices.launchValues`), listed as `launch_values`.
    static func handle(_ params: [String: JSONValue], launchValues: [String: Double] = [:]) -> JSONValue {
        let report = Self.report(launchValues: launchValues)
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

    /// The `debug.timings` field `launch_counters`: each first-frame value by name, empty
    /// until the first frame. The temperature is `launch_clock`'s.
    nonisolated static func counterReport(_ values: [StartupCounterReader.Value]) -> JSONValue {
        var report: [String: JSONValue] = [:]
        for value in values { report[value.name] = .number((value.value * 10).rounded() / 10) }
        return .object(report)
    }

    /// `debug.startup_trace`: writes what the startup trace holds now (on the files lane, never on main) and
    /// returns its status; `{"close": true}` closes it first. With no trace: `trace_ring_bytes` 0.
    nonisolated static var startupTraceMethod: ControlMethod {
        .async("debug.startup_trace") { call in
            guard let trace = launchMarks.withLock({ $0.marks.trace }) else { return ["enabled": false, "trace_ring_bytes": 0] }
            if call.params["close"]?.boolValue == true { trace.close() }
            let status = await trace.flush()
            return ["enabled": true, "file": .string(status.file.path), "seconds": .number(status.seconds),
                    "trace_ring_bytes": .number(Double(status.ringBytes)), "pending": .number(Double(status.pending)),
                    "dropped": .number(Double(status.dropped)), "written_events": .number(Double(status.written)),
                    "closed": .bool(status.closed), "failure": status.failure.map(JSONValue.string) ?? .null]
        }
    }

    private static func report(launchValues: [String: Double]) -> JSONValue {
        func round(_ ms: Double) -> JSONValue { .number((ms * 10).rounded() / 10) }
        var launch: [String: JSONValue] = [:]
        let (marks, slices) = launchMarks.withLock { ($0.marks.all, $0.slices) }
        for mark in marks { launch[mark.name] = round(mark.ms) }
        return [
            "launch_ms_since_process_start": .object(launch),
            // Numeric launch values kept in the process (`debug.startup` reads them as counters).
            "launch_values": .object(launchValues.mapValues { JSONValue.number($0) }),
            // The launch's clock: null until the main run loop's start reads the page-ins.
            "launch_clock": ["temperature": slices.temperature.map { JSONValue.string($0.name) } ?? .null,
                             "pageins": slices.pageins.map { JSONValue.number(Double($0)) } ?? .null,
                             "process_start_uptime_ns": .number(Double(slices.processStartNanos))],
            // The first frame's page-ins and main-thread CPU: values, never time marks.
            "launch_counters": counterReport(launchCounters.values),
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
