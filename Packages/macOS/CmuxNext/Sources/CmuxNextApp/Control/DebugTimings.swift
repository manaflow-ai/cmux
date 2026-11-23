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
import struct CmuxNextControl.LaunchMarkSink
import struct CmuxNextControl.LaunchTimesRecorder

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

    /// The launch marks so far, by name (`LaunchTimesRecorder.write(marks:)`).
    nonisolated static func launchMarkTimes() -> [String: Double] { launchMarks.withLock { Dictionary($0.map { ($0.name, $0.ms) }, uniquingKeysWith: { first, _ in first }) } }

    /// Milliseconds since the process started, on the launch marks' clock.
    nonisolated static func millisecondsSinceProcessStart(at date: Date = Date()) -> Double {
        date.timeIntervalSince(LaunchTimesRecorder.processStart) * 1_000
    }

    /// Records a launch mark (milliseconds since process start) once per
    /// name, from any thread.
    nonisolated static func markLaunch(_ name: String, at date: Date = Date()) {
        let ms = millisecondsSinceProcessStart(at: date)
        let first = launchMarks.withLock { marks in
            guard !marks.contains(where: { $0.name == name }) else { return false }
            marks.append((name, ms))
            return true
        }
        if first {
            LaunchMarkSink.shared.write(name: name, ms: ms)
            #if DEBUG || CMUX_BENCH_HOOKS
            UpdateHarness.mark("launch.\(name)", at: date)
            #endif
        }
    }

    static func install() {
        DaemonLaunchTimings.shared.install { markLaunch($0, at: $1) }
        AgentPaneLaunchTimings.shared.install { markLaunch($0, at: $1) }
        TerminalTimings.onSurfaceCreated = { duration in
            let ms = BenchSpans.ms(duration)
            if surfaces.count < capacity { surfaces.append(ms) }
            markLaunch("first_terminal_surface_created")
        }
    }

    /// Marks `reveal.<region>` when each launch region shows (its data
    /// landed, or the reveal deadline passed).
    static func markReveal(_ reveal: LaunchReveal) {
        for region in LaunchRegion.allCases {
            reveal.whenReady(region) { markLaunch("reveal.\(region.rawValue)"); if reveal.shownByDeadline.contains(region) { markLaunch("reveal.\(region.rawValue).by_deadline") } }
        }
    }

    static func palettePresented(_ timing: PaletteOpenTiming) {
        if paletteOpens.count < capacity { paletteOpens.append(timing) }
    }

    static func iconPickerOpened(_ timing: IconPickerOpenTiming) {
        if iconPickerOpens.count < capacity { iconPickerOpens.append(timing) }
    }

    static func chatsFeedApplied(lines: Int, _ duration: Duration) {
        if chatsFeedApplies.count < capacity { chatsFeedApplies.append((lines, BenchSpans.ms(duration))) }
    }

    static func turnStatesApplied(lines: Int, _ duration: Duration) {
        if turnStateApplies.count < capacity { turnStateApplies.append((lines, BenchSpans.ms(duration))) }
    }

    static func controlPublished(tabs: @autoclosure () -> Int, _ duration: Duration) {
        if controlPublishes.count < capacity { controlPublishes.append((tabs(), BenchSpans.ms(duration))) }
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
        let terminals = TerminalLaunchFrames.launchReport { millisecondsSinceProcessStart(at: $0) }.flatMap { try? JSONValue.parse($0) }
        return [
            "launch_terminals": terminals?["panes"] ?? .object([:]), "launch_terminals_frame_shown_max_ms": terminals?["max_ms"] ?? .null,
            "launch_ms_since_process_start": .object(launch),
            // The launch marks' zero on the wall clock (ms since 1970), so a page's own marks
            // (`Date.now()`) line up with them (bench_relaunch_reconnect.py).
            "process_start_epoch_ms": .number((LaunchTimesRecorder.processStart.timeIntervalSince1970 * 1_000).rounded()),
            "palette_opens": .array(paletteOpens.map { open in
                ["ms": round(BenchSpans.ms(open.total)), "input_ms": round(BenchSpans.ms(open.input)),
                 "key_to_frame_ms": round(BenchSpans.ms(open.keyToFrame)), "model_ms": round(BenchSpans.ms(open.model)),
                 "panel_ms": round(BenchSpans.ms(open.panel)), "present_ms": round(BenchSpans.ms(open.present)),
                 "commit_ms": round(BenchSpans.ms(open.commit)), "created_panel": .bool(open.createdPanel)]
            }),
            "icon_picker_opens": .array(iconPickerOpens.map { open in
                ["ms": round(BenchSpans.ms(open.total)), "catalog_ms": round(BenchSpans.ms(open.catalog)),
                 "page_ms": round(BenchSpans.ms(open.page)), "present_ms": round(BenchSpans.ms(open.present)),
                 "created_page": .bool(open.createdPage)]
            }),
            "omnibar_clicks": .array(omnibarClicks.map {
                ["engine": .string($0.engine), "input_ms": round($0.input), "key_to_frame_ms": round($0.keyToFrame)]
            }),
            "terminal_surfaces_ms": .array(surfaces.map(round)),
            "chats_feed_applies": .array(chatsFeedApplies.map { ["lines": .number(Double($0.lines)), "ms": .number(($0.ms * 1000).rounded() / 1000)] }),
            "turn_state_applies": .array(turnStateApplies.map { ["lines": .number(Double($0.lines)), "ms": .number(($0.ms * 1000).rounded() / 1000)] }),
            "control_publishes": .array(controlPublishes.map { ["tabs": .number(Double($0.tabs)), "ms": .number(($0.ms * 1000).rounded() / 1000)] }),
            "ghostty_runtime_ms": .object(Dictionary(TerminalTimings.runtimePhases.map { ($0.name, round(BenchSpans.ms($0.duration))) },
                                                     uniquingKeysWith: { first, _ in first })),
        ]
    }
}
