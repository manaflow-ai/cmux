#if DEBUG
import AppKit
import CmuxNextSettings
import CmuxNextTabs
import CmuxNextWakeups

/// `debug.motion` `trace_*` (DEBUG builds): the animated geometry of one window, sampled on each
/// tick of that window's display link, for the golden-interactions motion guard
/// (scripts/ci/frame-pacing/golden.py). A guard starts it, drives an interaction through the
/// socket, and stops it: an animation that ran shows as values that move over many frames; one
/// that was skipped shows as one jump.
///
/// `action` (after `trace_`): `start` (`window`, an index into the main windows, default 0; `targets`, any of
/// `tabs`, `sidebar` and `window`, default all), `stop` (the samples, then idle) or `read`.
/// Each sample has `t` (ms since the first tick) and, per target: `tabs` (each tab cell of the
/// focused pane's strip as `[id, x, width, opacity]`, by x), `sidebar` (`[width, presented
/// width]` of the sidebar container) and `window` (`[window width, height, focused pane
/// content width, height]`). `stop` also lists `looping`: animations in the window's own
/// layer tree that repeat (Reduce Motion should leave none). A run ends by itself after
/// ``maximumRun``, so a client that never stops leaves no display link running.
@MainActor
final class DebugTraceFrames {
    static let shared = DebugTraceFrames()
    static let maximumRun: Duration = .seconds(30)
    static let capacity = 6_000

    private var client: FrameClient?
    private let expiry = DemandTimer(owner: "debug.motion.trace.expiry")
    private weak var controller: WindowController?
    private var targets: Set<String> = []
    private var first: CFTimeInterval = 0
    private var refresh: Double = 0
    private var samples: [JSONValue] = []

    func handle(_ params: [String: JSONValue], _ services: AppServices?) -> JSONValue {
        switch params["action"]?.stringValue ?? "read" {
        case "start":
            guard let services else { return .object(["error": .string("no app services")]) }
            let index = params["window"]?.intValue ?? 0
            let controllers = services.windows.controllers
            guard controllers.indices.contains(index), let view = controllers[index].window?.contentView else {
                return .object(["error": .string("no such window")])
            }
            stop()
            controller = controllers[index]
            targets = Set(params["targets"]?.arrayValue?.compactMap(\.stringValue) ?? ["tabs", "sidebar", "window"])
            samples.removeAll(keepingCapacity: true)
            first = 0
            let client = FrameClient(owner: "debug.motion.trace", isAnimation: false,
                                     scheduler: { [weak view] in view.map(FrameScheduler.forView) ?? .app }) { [weak self] tick in
                self?.tick(tick) ?? false
            }
            self.client = client
            client.activate()
            expiry.schedule(after: Self.maximumRun) { @MainActor [weak self] in self?.stop() }
            return .object(["running": .bool(true)])
        case "stop":
            let report = self.report(looping: true)
            stop()
            return report
        default:
            return report(looping: false)
        }
    }

    private func stop() {
        client?.deactivate()
        client = nil
        expiry.cancel()
    }

    private func tick(_ tick: FrameTick) -> Bool {
        guard let controller, samples.count < Self.capacity else { return false }
        if let interval = tick.refreshInterval { refresh = interval }
        if first == 0 { first = tick.timestamp }
        var sample: [String: JSONValue] = ["t": .number(((tick.timestamp - first) * 100_000).rounded() / 100)]
        let pane = controller.content?.focusedPane
        if targets.contains("tabs"), let strip = pane?.view.stripView {
            sample["tabs"] = .array(TabStripDebug.tabFrames(in: strip).map {
                .array([.string($0.id), Self.number($0.frame.minX), Self.number($0.frame.width), Self.number(Double($0.opacity))])
            })
        }
        if targets.contains("sidebar") {
            let container = controller.sidebar.container
            let presented = container.layer?.presentation()?.bounds.width ?? container.frame.width
            sample["sidebar"] = .array([Self.number(container.frame.width), Self.number(presented)])
        }
        if targets.contains("window"), let window = controller.window {
            let host = pane?.view.contentHost.bounds.size ?? .zero
            sample["window"] = .array([Self.number(window.frame.width), Self.number(window.frame.height),
                                       Self.number(host.width), Self.number(host.height)])
        }
        samples.append(.object(sample))
        return true
    }

    private func report(looping: Bool) -> JSONValue {
        var report: [String: JSONValue] = [
            "running": .bool(client?.isActive == true), "refresh_ms": .number((refresh * 100_000).rounded() / 100),
            "samples": .array(samples),
        ]
        if looping, let root = controller?.window?.contentView?.superview?.layer ?? controller?.window?.contentView?.layer {
            report["looping"] = .array(Self.repeatingAnimations(under: root).map(JSONValue.string))
        }
        return .object(report)
    }

    /// `layer class/name/key` of every animation under `root` that repeats or reverses forever.
    private static func repeatingAnimations(under root: CALayer) -> [String] {
        var found: [String] = []
        var stack = [root]
        var visited = 0
        while let layer = stack.popLast(), visited < 20_000 {
            visited += 1
            for key in layer.animationKeys() ?? [] {
                guard let animation = layer.animation(forKey: key),
                      animation.repeatCount > 1 || animation.repeatDuration > 0 else { continue }
                found.append("\(type(of: layer))/\(layer.name ?? "")/\(key)")
            }
            stack.append(contentsOf: layer.sublayers ?? [])
        }
        return found
    }

    private static func number(_ value: CGFloat) -> JSONValue { .number((Double(value) * 100).rounded() / 100) }
    private static func number(_ value: Double) -> JSONValue { .number((value * 100).rounded() / 100) }
}
#endif
