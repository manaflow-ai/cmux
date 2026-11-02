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
/// frame (`MotionTrace.measure`). `bounce` with `value` ("none", "subtle") and `kind` with
/// `name` ("paneAnimations", "newTab", "newWorkspace") and `value` true or false set
/// `ui.animations.bounce`, `ui.paneAnimations` and `ui.animations.*` in memory the same way.
/// The report lists the display links alive (`display_links`: 0 once every spring rests, so
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
        case "speed":
            if let value = params["value"] as? String, let speed = MotionSpeed(rawValue: value) {
                DesignSettings.shared.animationSpeed = speed
            }
        case "reduce":
            Motion.reduceMotionOverride = params["value"] as? Bool
        case "bounce":
            if let value = params["value"] as? String, let bounce = MotionBounce(rawValue: value) {
                DesignSettings.shared.animationBounce = bounce
            }
        case "kind":
            if let name = params["name"] as? String, let on = params["value"] as? Bool {
                if name == "paneAnimations" {
                    DesignSettings.shared.paneAnimations = on
                } else if let kind = MotionKind(rawValue: name) {
                    if on { DesignSettings.shared.enabledAnimations.insert(kind) } else { DesignSettings.shared.enabledAnimations.remove(kind) }
                }
            }
        case "stop":
            let report = self.report
            commitProbe?.stop()
            MotionTrace.stop()
            return report
        default:
            break
        }
        return report
    }

    private static var report: [String: Any] {
        let policy = Motion.basePolicy
        return [
            "recording": MotionTrace.isEnabled,
            "speed": policy.speed.rawValue,
            "reduce_motion": policy.reduceMotion,
            "bounce": policy.bounce.rawValue,
            "enabled_kinds": policy.enabledKinds.map(\.rawValue).sorted(),
            "animations_enabled": policy.animationsEnabled,
            "disabled_categories": policy.disabledCategories.map(\.rawValue).sorted(),
            "pane_animations": DesignSettings.shared.paneAnimations,
            "display_links": FrameScheduler.all.filter(\.hasLink).count,
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
                return ["frames": sorted.count, "p50_ms": at(0.5), "p95_ms": at(0.95), "max_ms": at(1), "over_4_ms": sorted.filter { $0 > 4 }.count]
            },
        ]
    }
}
