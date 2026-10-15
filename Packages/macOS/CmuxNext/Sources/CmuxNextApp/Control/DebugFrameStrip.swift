#if DEBUG
import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextTabs
import CmuxNextWakeups

/// `debug.new_tab {action: "frame_strip"}` (DEBUG builds): the window as the window server
/// composited it, frame after frame, around one key sent through the real key path (`key`, default
/// `n`, with `modifiers`, default `["command"]`: Cmd-N; `t` for Cmd-T) or a `gesture` (`plus`,
/// `drag_new`). Frames are read off the main actor back to back for `duration_ms` (default 700) after
/// the key, and some before it. The report: ``WindowFrameStrip``; motion knobs: ``MotionFrameProgress``.
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
        let recording = Task.detached { await WindowFrame.record(number, scale: scale, from: start, until: 120 + duration) }
        // The key goes in once the recorder has frames from before it.
        let lead = DemandTimer(owner: "debug.frame_strip.lead")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            lead.schedule(after: .milliseconds(120)) { @MainActor in done.resume() }
        }
        let sent: JSONValue
        if params["gesture"]?.stringValue == "plus", let pane = controller.content?.focusedPane {
            pane.stripModel.send(.newTab(after: nil))
            sent = .string("plus")
        } else if params["gesture"]?.stringValue == "drag_new", let pane = controller.content?.focusedPane {
            let dragged = await TabStripDebug.dragFirstTab(in: pane.view.stripView) {
                _ = services.registry.perform("newSurface", invocation: ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.paneKey), origin: .cli))
            }
            sent = .string(dragged ? "drag_new" : "drag_new: no tab")
        } else {
            sent = DebugKey.send(["key": .string(params["key"]?.stringValue ?? "n"), "modifiers": params["modifiers"] ?? .array([.string("command")]),
                                  "window": .string(controller.state.id)], services: services)
        }
        let sentAt = BenchSpans.ms(.now - start), sentTime = CACurrentMediaTime()
        let frames = await recording.value
        let spans = BenchSpans.end()
        let pane = controller.content?.focusedPane
        guard let report = await WindowFrameStrip.report(frames, window: window, sentAt: sentAt, sentTime: sentTime,
                                                         content: params["content"]?.stringValue == "none" ? nil : pane?.view.contentHost,
                                                         strip: pane?.view.stripView, tolerance: tolerance, jump: params["jump"]?.doubleValue, dir: dir),
              case .object(var fields)? = JSONValue(foundation: report)
        else { return .object(["error": .string("no frames"), "key": sent]) }
        fields["key"] = sent
        fields["spans"] = .array(spans.map { .object(["name": .string($0.name), "ms": .number(($0.start - sentAt).rounded()), "duration_ms": .number($0.milliseconds)]) })
        return .object(fields)
    }
}
#endif
