#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextCompat
import CmuxNextWakeups

/// `debug.motion` `trace_*` (DEBUG builds): one window's animated geometry, sampled on each
/// tick of that window's display link, for the golden-interactions motion guard
/// (scripts/ci/frame-pacing/golden.py). A guard starts it, drives an interaction through the
/// socket and stops it: an animation that ran shows as values that move over many frames;
/// one that was skipped shows as one jump.
///
/// After `trace_`: `start` (`window`, an index into `windows`, default 0; `targets`, keys
/// to keep, default all; `window` also keeps `strip`), `stop` (the samples, then idle) or
/// `read`. `stop` and `read` with `path` reply with counts only and write the full report to `path` off the main
/// thread (use it for long traces: the reply's serialization is main-thread work). Each sample has `t` (ms since the first tick), `window` (`[width, height]`) and
/// the keys the samplers give for the views they know: `tabs` (`[id, x, width, opacity]` per tab cell),
/// `strip` (each tab strip's width: the pane content follows it in a live resize) and
/// `sidebar` (`[width, presented width]`). Every report has `t0_s`, the first tick's host time. `stop` also lists `looping`: animations in the
/// window's own layer tree that repeat (Reduce Motion should leave none). A run ends by
/// itself after ``maximumRun``, so a client that never stops leaves no display link running.
final class MotionFrameTrace {
    /// A view's values this frame by key, or nil for a view the sampler does not know. Values
    /// several views give under one key are joined.
    typealias Sampler = @MainActor (NSView) -> [String: [Any]]?

    static let shared = MotionFrameTrace()
    /// `debug.motion` `record_*`'s recorder, kept beside the trace so a run can record and trace one window.
    let recorder = MotionScreenRecord()
    static let maximumRun: Duration = .seconds(30)
    static let capacity = 6_000

    private struct Traced {
        weak var view: NSView?
        var sampler: Sampler
    }

    private var client: FrameClient?
    private let expiry = DemandTimer(owner: "debug.motion.trace.expiry")
    private weak var window: NSWindow?
    private var views: [Traced] = []
    private var targets: Set<String>?
    private var first: CFTimeInterval = 0
    private var refresh: Double = 0
    private var samples: [[String: Any]] = []

    func handle(_ action: String, _ params: [String: Any], windows: [NSWindow], samplers: [Sampler]) -> [String: Any] {
        switch action {
        case "start":
            let index = params["window"] as? Int ?? 0
            guard windows.indices.contains(index), let content = windows[index].contentView else { return ["error": "no such window"] }
            stop()
            window = windows[index]
            targets = (params["targets"] as? [String]).map(Set.init)
            views = Self.traced(under: content.superview ?? content, samplers)
            samples.removeAll(keepingCapacity: true)
            first = 0
            let client = FrameClient(owner: "debug.motion.trace", isAnimation: false,
                                     scheduler: { [weak content] in content.map(FrameScheduler.forView) ?? .app }) { [weak self] tick in
                self?.tick(tick) ?? false
            }
            self.client = client
            client.activate()
            expiry.schedule(after: Self.maximumRun) { @MainActor [weak self] in self?.stop() }
            return ["running": true, "views": views.count]
        case "stop":
            if let path = params["path"] as? String { return writeReport(to: path, looping: true, stopping: true) }
            let report = self.report(looping: true)
            stop()
            return report
        default:
            if let path = params["path"] as? String { return writeReport(to: path, looping: false, stopping: false) }
            return report(looping: false)
        }
    }

    private func stop() {
        client?.deactivate()
        client = nil
        expiry.cancel()
    }

    private func wanted(_ key: String) -> Bool {
        guard let targets else { return true }
        return targets.contains(key) || (key == "strip" && targets.contains("window"))
    }

    private func tick(_ tick: FrameTick) -> Bool {
        guard let window, samples.count < Self.capacity else { return false }
        if let interval = tick.refreshInterval { refresh = interval }
        if first == 0 { first = tick.timestamp }
        var sample: [String: Any] = ["t": Self.round((tick.timestamp - first) * 1_000)]
        if wanted("window") { sample["window"] = [Self.round(window.frame.width), Self.round(window.frame.height)] }
        for traced in views {
            guard let view = traced.view, let values = traced.sampler(view) else { continue }
            for (key, values) in values where wanted(key) {
                sample[key] = (sample[key] as? [Any] ?? []) + values
            }
        }
        samples.append(sample)
        return true
    }

    /// The serialization of a long trace (700 samples of every pane and divider: 85 ms on the main thread, STATUS
    /// 4782) runs here, never on the main thread.
    private let writer = DispatchQueue(label: "debug.motion.trace", qos: .utility)

    /// `stop` or `read` with `path`: the reply is small (counts and the path); the full report is serialized and
    /// written to `path` off the main thread (`path.tmp`, then renamed, so a reader never sees half a file). The main
    /// thread only copies the samples (copy-on-write) and reads the window's layers for `looping`.
    private func writeReport(to path: String, looping: Bool, stopping: Bool) -> [String: Any] {
        let report = self.report(looping: looping)
        if stopping { stop() }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let handed = Handed(report)
        writer.async {
            guard let data = try? JSONSerialization.data(withJSONObject: handed.value) else { return }
            let temporary = url.appendingPathExtension("tmp")
            do {
                try data.blockingWrite(to: temporary)
                try? FileManager.checked.removeItem(at: url)
                try FileManager.checked.moveItem(at: temporary, to: url)
            } catch {
                try? FileManager.checked.removeItem(at: temporary)
            }
        }
        return ["path": url.path, "writing": true, "samples": samples.count, "refresh_ms": report["refresh_ms"] ?? 0,
                "t0_s": first, "running": client?.isActive == true]
    }

    /// The report handed to the writer queue once; the main actor never touches it again.
    // crash-allow: a [String: Any] of numbers, strings and arrays the main actor built and no longer mutates.
    private nonisolated struct Handed: @unchecked Sendable {
        let value: [String: Any]
        init(_ value: [String: Any]) { self.value = value }
    }

    private func report(looping: Bool) -> [String: Any] {
        // `t0_s`: the first tick's host time (CACurrentMediaTime's clock, seconds), so a sample's `t` lines up
        // with other clocks of this host (`record_*`'s frame display times, the input journal).
        var report: [String: Any] = ["running": client?.isActive == true, "refresh_ms": Self.round(refresh * 1_000), "samples": samples,
                                     "t0_s": first]
        if looping, let root = window?.contentView?.superview?.layer ?? window?.contentView?.layer {
            report["looping"] = Self.repeatingAnimations(under: root)
        }
        return report
    }

    /// Every view under `view` a sampler knows, with that sampler.
    private static func traced(under view: NSView, _ samplers: [Sampler]) -> [Traced] {
        var found: [Traced] = []
        var stack = [view]
        while let next = stack.popLast() {
            if let sampler = samplers.first(where: { $0(next) != nil }) { found.append(Traced(view: next, sampler: sampler)) }
            stack.append(contentsOf: next.subviews)
        }
        return found
    }

    /// `layer class/name/key` of every animation under `root` that repeats or reverses forever.
    private static func repeatingAnimations(under root: CALayer) -> [String] {
        var found: [String] = []
        var stack = [root]
        var visited = 0
        while let layer = stack.popLast(), visited < 20_000 {
            visited += 1
            for key in layer.animationKeys() ?? [] {
                guard let animation = layer.animation(forKey: key), animation.repeatCount > 1 || animation.repeatDuration > 0 else { continue }
                found.append("\(type(of: layer))/\(layer.name ?? "")/\(key)")
            }
            stack.append(contentsOf: layer.sublayers ?? [])
        }
        return found
    }

    static func round(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}
#endif
