public import AppKit
import CmuxNextWakeups
public import CmuxNextDesignTokens

/// `debug.motion` (DEBUG builds register it; `DebugMotion` in CmuxNextApp is its wiring):
/// `start` begins recording animation spans, `read` returns them, `stop` returns them and
/// stops. Each span runs from an animation's first frame to rest (plans/cmux-next/motion.md
/// "Verification"). `speed` with `value` ("fast", "normal", "off") sets the live speed in
/// memory only, so a bench can compare speeds without writing cmux.json; the next cmux.json
/// load restores the file's value. `reduce` with `value` true or false overrides Reduce
/// Motion in memory (null follows the system setting again), so a bench records reduced
/// motion without the system setting. `work` is each timed animation's main-thread work per
/// frame (`MotionTrace.measure`): a summary, and `each_ms`, every frame's time in the order
/// recorded. `kind` with `name` ("paneAnimations", "newTab",
/// "newWorkspace") and `value` true or false sets `ui.paneAnimations` and `ui.animations.*`
/// in memory the same way.
/// The report lists the display links running (`display_links`: 0 once every spring rests, so
/// the window idles). Spans carry `at_ms` (from `start`); `samples` lists per-frame values
/// (`clock.dt_ms`, and `tabs.travel`, `layout.travel`, `sidebar.open`: the points an
/// animator has left to move); `notes` lists what an animator decided. `trajectory` (answered
/// by the app's wiring) returns the port's motion parity corpus (`MotionParityCorpus`), the
/// document cmux-motion's `motion_trajectories` example prints; scripts/cmux-next/motion-parity.py
/// compares the two. `trace_start`, `trace_read` and `trace_stop` sample
/// animated geometry on every display frame instead (DEBUG and bench builds, ``MotionFrameTrace``); `record_start`,
/// `record_read` and `record_stop` record the window as the window server composites it, every frame, as a movie
/// (``MotionScreenRecord``).
/// Takes and returns `JSONSerialization` object graphs.
public struct MotionDebug {
    public init() {}
    /// Samplers other modules add for `trace_*` (the layout's pane hosts), after the caller's.
    @MainActor public static var registeredSamplers: [@MainActor (NSView) -> [String: [Any]]?] = []
    /// `samplers` read the animated geometry of the views they know (DEBUG builds: ``MotionFrameTrace``).
    /// `commitProbe` (the handler's own) times each Core Animation commit from `start` to `stop`
    /// (`work` `ca.commit`).
    public static func handle(_ params: [String: Any], windows: [NSWindow], samplers: [@MainActor (NSView) -> [String: [Any]]?] = [],
                              commitProbe: MotionCommitProbe? = nil) -> [String: Any] {
        let action = params["action"] as? String ?? "read"
        #if DEBUG || CMUX_BENCH_HOOKS
        if action.hasPrefix("trace_") {
            return MotionFrameTrace.shared.handle(String(action.dropFirst("trace_".count)), params, windows: windows, samplers: samplers + registeredSamplers)
        }
        if action.hasPrefix("record_") {
            return MotionFrameTrace.shared.recorder.handle(String(action.dropFirst("record_".count)), params, windows: windows)
        }
        #endif
        switch action {
        case "start":
            MotionTrace.start()
            commitProbe?.start()
            commitProbe?.turns.start()
        case "speed":
            if let value = params["value"] as? String, let speed = MotionSpeed(rawValue: value) {
                DesignSettings.shared.animationSpeed = speed
            }
        case "reduce":
            Motion.reduceMotionOverride = params["value"] as? Bool
        case "kind":
            if let name = params["name"] as? String, let on = params["value"] as? Bool {
                if name == "paneAnimations" {
                    DesignSettings.shared.paneAnimations = on
                } else if name == "probe.hideFirst" {
                    for view in hideOrderSwitches(in: windows) { view.hidesBeforeMovesGo = on } // a measure branch's switch
                } else if let kind = MotionKind(rawValue: name) {
                    if on { DesignSettings.shared.enabledAnimations.insert(kind) } else { DesignSettings.shared.enabledAnimations.remove(kind) }
                }
            }
        case "stop":
            var last = Self.report(windows: windows, turns: commitProbe?.turns)
            // A measure branch's field, in the stop's reply only: each turn of the record that the turn probe kept, as
            // [its end in ms from `start`, its length, its part before the commit, its commit part] (ms). Made here,
            // when the record is read, never in a turn.
            if let turns = commitProbe?.turns {
                last["turns_each"] = turns.each.map { turn -> [Double] in
                    [((turn.end - MotionTrace.startedAt) * 100_000).rounded() / 100, (turn.total * 100).rounded() / 100,
                     (turn.beforeCommit * 100).rounded() / 100, (turn.commit * 100).rounded() / 100]
                }
            }
            commitProbe?.stop()
            commitProbe?.turns.stop()
            MotionTrace.stop()
            return last
        default:
            break
        }
        return Self.report(windows: windows, turns: commitProbe?.turns)
    }

    /// Each view in `windows` that reaches a pane motion with the measure branch's switch (a pane's host).
    private static func hideOrderSwitches(in windows: [NSWindow]) -> [any MotionHideOrderSwitching] {
        var found: [any MotionHideOrderSwitching] = []
        var left: [NSView] = windows.compactMap { $0.contentView }
        while let view = left.popLast() {
            if let one = view as? any MotionHideOrderSwitching { found.append(one) }
            left.append(contentsOf: view.subviews)
        }
        return found
    }

    private static func report(windows: [NSWindow], turns: MotionTurnProbe?) -> [String: Any] {
        let policy = Motion.basePolicy
        let switches = hideOrderSwitches(in: windows)
        return [
            "recording": MotionTrace.isEnabled,
            // A measure branch's fields: the record's start on the uptime clock (a frame's and a stall's clock), so a
            // reader puts a span, a note and a late frame on one line of time; the turn probe's own counts; the switch
            // (on in a screen that the windows show).
            "started_s": MotionTrace.startedAt,
            "turn_probe": ["callbacks": turns?.callbacks ?? 0, "turns": turns?.turns ?? 0, "noted": turns?.noted ?? 0] as [String: Any],
            "probe_hide_first": switches.contains(where: { $0.hidesBeforeMovesGo }),
            "speed": policy.speed.rawValue,
            "reduce_motion": policy.reduceMotion,
            "enabled_kinds": policy.enabledKinds.map(\.rawValue).sorted(),
            "animations_enabled": policy.animationsEnabled,
            "disabled_categories": policy.disabledCategories.map(\.rawValue).sorted(),
            "pane_animations": DesignSettings.shared.paneAnimations,
            "display_links": FrameScheduler.all.filter(\.isRunning).count,
            "active_clients": FrameScheduler.all.flatMap(\.activeClients),
            "spans": MotionTrace.spans.map { span -> [String: Any] in
                ["name": span.name, "ms": (span.milliseconds * 10).rounded() / 10,
                 "at_ms": ((span.start - MotionTrace.startedAt) * 10000).rounded() / 10]
            },
            // Per-frame values (clock dt, travel left per animator), ms from `start`.
            "samples": MotionTrace.samples.map { sample -> [String: Any] in
                ["name": sample.name, "t_ms": ((sample.time - MotionTrace.startedAt) * 10000).rounded() / 10,
                 "v": (sample.value * 100).rounded() / 100]
            },
            // What an animator decided, ms from `start` (the tab strip's syncs: added, removed, animated).
            "notes": MotionTrace.notes.map { note -> [String: Any] in
                ["t_ms": ((note.time - MotionTrace.startedAt) * 10000).rounded() / 10, "text": note.text]
            },
            "work": MotionTrace.work.mapValues { frames -> [String: Any] in
                let sorted = frames.sorted()
                func at(_ p: Double) -> Double { ((sorted.isEmpty ? 0 : sorted[Int((Double(sorted.count - 1) * p).rounded())]) * 100).rounded() / 100 }
                // `each_ms`: every frame's time in the order recorded, so a reader can leave out a frame that the host
                // disturbed. Made here, when the record is read, never in a frame; no longer than `MotionTrace.record`'s
                // bound for a name.
                return ["frames": sorted.count, "p50_ms": at(0.5), "p95_ms": at(0.95), "max_ms": at(1), "over_4_ms": sorted.filter { $0 > 4 }.count,
                        "each_ms": frames.map { ($0 * 100).rounded() / 100 }]
            },
        ]
    }
}

/// A measure branch's switch (`debug.motion` kind `probe.hideFirst`, off at launch): a view whose pane motion hides the
/// panes that its change took out BEFORE it takes the moves off the layers, so a bench can time the same hide in the
/// two orders. The product's order is the other one. The pane motion owns the state; `debug.motion` sets it through
/// each view of the windows that reaches one.
@MainActor public protocol MotionHideOrderSwitching: AnyObject {
    var hidesBeforeMovesGo: Bool { get set }
}
