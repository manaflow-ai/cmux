#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextTabs
import CmuxNextWakeups

/// `debug.new_tab {action: "frame_strip"}` (DEBUG builds): the window as the window server
/// composited it, frame after frame, around one key sent through the real key path (`key`, default
/// `n`, with `modifiers`, default `["command"]`: Cmd-N; `t` for Cmd-T) or a `gesture` (`plus`,
/// `drag_new`). `repeat` (default 1) sends the key that many times, `repeat_interval_ms` (default 40)
/// apart, inside one recording (a fast selection burst retargets moves in flight). Frames are read off the main actor back to back for `duration_ms` (default 700) after
/// the key, and some before it. The report: ``NSWindow/frameStripReport(_:sentAt:sentTime:content:strip:tolerance:jump:dir:)``; motion knobs: ``MotionFrameProgress``.
@MainActor
enum DebugFrameStrip {
    static func run(_ params: [String: JSONValue], _ controller: WindowController, _ services: AppServices) async -> JSONValue {
        guard let window = controller.window, window.windowNumber > 0 else { return .object(["error": .string("no window")]) }
        let number = CGWindowID(window.windowNumber)
        let scale = params["scale"]?.doubleValue ?? 0.25
        let duration = params["duration_ms"]?.doubleValue ?? 700
        let tolerance = params["tolerance"]?.doubleValue ?? 0.002
        let dir = params["dir"]?.stringValue ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("frame-strip-\(UUID().uuidString)")
        // The app's bench marks around the key come back with the frames (`spans`, ms from the key).
        BenchSpans.begin()
        let start = ContinuousClock.now
        // `crop: "strip"`: only the focused pane's tab strip is kept (full scale stays cheap); the report
        // then measures the strip alone.
        let cropsStrip = params["crop"]?.stringValue == "strip"
        let crop = cropsStrip ? controller.content?.focusedPane.flatMap { window.unitRect(of: $0.view.stripView) } : nil
        let recording = Task.detached { await WindowFrame.record(number, scale: scale, crop: crop, from: start, until: 120 + duration) }
        // The key goes in once the recorder has frames from before it.
        let lead = DemandTimer(owner: "debug.frame_strip.lead")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            lead.schedule(after: .milliseconds(120)) { @MainActor in done.resume() }
        }
        let sent: JSONValue
        // When the first key went in (a burst's later keys come after it).
        var firstSent: (ms: Double, time: CFTimeInterval)?
        if params["gesture"]?.stringValue == "plus", let pane = controller.content?.focusedPane {
            pane.stripModel.send(.newTab(after: nil))
            sent = .string("plus")
        } else if params["gesture"]?.stringValue == "drag_new", let pane = controller.content?.focusedPane {
            let dragged = await TabStripDebug.dragFirstTab(in: pane.view.stripView) {
                _ = services.registry.perform("newSurface", invocation: ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.paneKey), origin: .cli))
            }
            sent = .string(dragged ? "drag_new" : "drag_new: no tab")
        } else {
            let keyParams: [String: JSONValue] = ["key": .string(params["key"]?.stringValue ?? "n"), "modifiers": params["modifiers"] ?? .array([.string("command")]),
                                                  "window": .string(controller.state.id)]
            sent = DebugKey.send(keyParams, services: services)
            firstSent = (BenchSpans.ms(.now - start), CACurrentMediaTime())
            let count = max(1, Int(params["repeat"]?.doubleValue ?? 1))
            if count > 1 {
                let interval = max(1, Int(params["repeat_interval_ms"]?.doubleValue ?? 40))
                let gap = DemandTimer(owner: "debug.frame_strip.repeat")
                for _ in 1..<count {
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        gap.schedule(after: .milliseconds(interval)) { @MainActor in done.resume() }
                    }
                    _ = DebugKey.send(keyParams, services: services)
                }
            }
        }
        let (sentAt, sentTime) = firstSent ?? (BenchSpans.ms(.now - start), CACurrentMediaTime())
        let frames = await recording.value
        let spans = BenchSpans.end()
        let pane = controller.content?.focusedPane
        guard let report = await window.frameStripReport(frames, sentAt: sentAt, sentTime: sentTime,
                                                         content: params["content"]?.stringValue == "none" || crop != nil ? nil : pane?.view.contentHost,
                                                         strip: crop != nil ? nil : pane?.view.stripView, tolerance: tolerance, jump: params["jump"]?.doubleValue, dir: dir),
              case .object(var fields)? = JSONValue(foundation: report)
        else { return .object(["error": .string("no frames"), "key": sent]) }
        fields["key"] = sent
        fields["spans"] = .array(spans.map { .object(["name": .string($0.name), "ms": .number(($0.start - sentAt).rounded()), "duration_ms": .number($0.milliseconds)]) })
        return .object(fields)
    }
}
#endif
