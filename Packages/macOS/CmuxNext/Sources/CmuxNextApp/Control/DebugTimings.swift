import AppKit
import class CmuxNextAgentPane.AgentPaneLaunchTimings
import CmuxNextControl
import CmuxNextDesign
import CmuxNextLaunch
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

    /// Launch marks from any thread (the daemon start path runs off main), and the startup trace they go
    /// to when the launch asked for one (`CMUX_TRACE_STARTUP`).
    private nonisolated static let launchMarks = Mutex<LaunchMarks>(LaunchMarks())
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

    /// Records a launch mark (milliseconds since process start) once per
    /// name, from any thread. The first record of a name goes to
    /// ``LaunchMarkSink``: a launch os_signpost in every build, and the
    /// bench's pipe when one was passed; and to the startup trace when one is attached.
    nonisolated static func markLaunch(_ name: String, at date: Date = Date()) {
        let (ms, trace) = launchMarks.withLock { ($0.record(name, at: date, processStart: LaunchMarks.processStart), $0.trace) }
        guard let ms else { return }
        LaunchMarkSink.shared.write(name: name, ms: ms)
        LaunchMarks.forward(name, at: date, to: trace)
        #if DEBUG || CMUX_BENCH_HOOKS
        UpdateHarness.mark("launch.\(name)", at: date)
        #endif
    }

    /// The launch marks so far (`debug.startup`).
    nonisolated static var launchMarksNow: LaunchMarks { launchMarks.withLock { $0 } }

    /// The startup trace `CMUX_TRACE_STARTUP` asks for, attached before the first mark (`main`).
    nonisolated static func makeStartupTrace() -> StartupTrace? {
        guard let trace = StartupTrace.fromEnvironment(processStartNanos: LaunchMarks.processStartUptimeNanos) else { return nil }
        launchMarks.withLock { $0.attach(trace, processStart: LaunchMarks.processStart) }
        return trace
    }

    /// - Parameters:
    ///   - watchdog: Sends main-thread turns over 1 ms to `startupTrace` until it closes.
    ///   - startupTrace: The launch's startup trace (``makeStartupTrace()``), or nil.
    static func install(watchdog: MainThreadWatchdog, startupTrace: StartupTrace?) {
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

    /// `debug.startup_trace`: writes what the startup trace holds now (on the files lane, never on main) and
    /// returns its status; `{"close": true}` closes it first. With no trace: `trace_ring_bytes` 0.
    nonisolated static var startupTraceMethod: ControlMethod {
        .async("debug.startup_trace") { call in
            guard let trace = launchMarks.withLock({ $0.trace }) else { return ["enabled": false, "trace_ring_bytes": 0] }
            if call.params["close"]?.boolValue == true { trace.close() }
            let status = await trace.flush()
            return ["enabled": true, "file": .string(status.file.path), "seconds": .number(status.seconds),
                    "trace_ring_bytes": .number(Double(status.ringBytes)), "pending": .number(Double(status.pending)),
                    "dropped": .number(Double(status.dropped)), "written_events": .number(Double(status.written)),
                    "closed": .bool(status.closed), "failure": status.failure.map(JSONValue.string) ?? .null]
        }
    }

    private static var report: JSONValue {
        func round(_ ms: Double) -> JSONValue { .number((ms * 10).rounded() / 10) }
        var launch: [String: JSONValue] = [:]
        for mark in launchMarks.withLock({ $0.all }) { launch[mark.name] = round(mark.ms) }
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
