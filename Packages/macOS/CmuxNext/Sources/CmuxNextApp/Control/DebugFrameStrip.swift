#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextTabs
import CmuxNextWakeups

/// `debug.new_tab {action: "frame_strip"}` (DEBUG builds): the window as the window server
/// composited it, frame after frame, around one key sent through the real key path (`key`, default
/// `n`, with `modifiers`, default `["command"]`: Cmd-N; `t` for Cmd-T) or a `gesture` (`plus`,
/// `drag_new`, `mouse` with `mouse`: `debug.mouse`'s params, such as a click on a sidebar row, sent on its event path, or
/// `agent_click` with `click`: `debug.agent_pane click`'s params, a real click on an element of a chat's page, found before
/// the recording starts). `content: "rightmost"` judges the rightmost pane's content area instead of the focused pane's. `repeat` (default 1) sends the key that many times, `repeat_interval_ms` (default 40)
/// apart, inside one recording (a fast selection burst retargets moves in flight). Frames are read off the main actor back to back for `duration_ms` (default 700) after
/// the key, and some before it (`above`: ``FrameStripRecording``, ScreenCaptureKit without the Screen Recording grant; `capture` in the report). The report: ``NSWindow/frameStripReport(_:sentAt:sentTime:content:strip:tolerance:jump:dir:)``; motion knobs: ``MotionFrameProgress``.
@MainActor
enum DebugFrameStrip {
    static func run(_ params: [String: JSONValue], _ controller: WindowController, _ services: AppServices) async -> JSONValue {
        guard let window = controller.window, window.windowNumber > 0 else { return .object(["error": .string("no window")]) }
        let number = CGWindowID(window.windowNumber)
        let scale = params["scale"]?.doubleValue ?? 0.25
        let duration = params["duration_ms"]?.doubleValue ?? 700
        let tolerance = params["tolerance"]?.doubleValue ?? 0.002
        let dir = params["dir"]?.stringValue ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("frame-strip-\(UUID().uuidString)")
        // `agent_click`: the element is found in the chat's page before the recording starts, so the strip
        // times the click alone (DebugAgentPaneClick).
        var agentClick: (params: [String: JSONValue], pane: String, view: AgentPaneView, located: [String: Any])?
        if params["gesture"]?.stringValue == "agent_click" {
            guard case let .object(click)? = params["click"] else { return .object(["error": .string("agent_click needs click: {selector or text}")]) }
            switch DebugAgentPane.agentPane(click, services: services) {
            case let .success((pane, view)):
                let located = await DebugAgentPaneClick.locate(click, view: view)
                if let error = located["error"] as? String { return .object(["error": .string("agent_click: \(error)")]) }
                agentClick = (click, pane, view, located)
            case let .failure(failure):
                return .object(["error": .string("agent_click: \(failure.message)")])
            }
        }
        // The app's bench marks around the key come back with the frames (`spans`, ms from the key).
        BenchSpans.begin()
        let start = ContinuousClock.now
        // `crop: "strip"`: only the focused pane's tab strip is kept (full scale stays cheap); the report
        // then measures the strip alone.
        let crop = params["crop"]?.stringValue == "strip" ? controller.content?.focusedPane.flatMap { window.unitRect(of: $0.view.stripView) } : nil
        let above = params["above"]?.boolValue == true && crop == nil ? window.frameStripBounds : nil
        let recording = FrameStripRecording(number, above: above, crop: crop, scale: scale, from: start, lead: 120, duration: duration, capture: params["capture"]?.stringValue)
        await recording.waitForLead() // The key goes in once the recorder has frames from before it.
        let sent: JSONValue
        var firstSent: (ms: Double, time: CFTimeInterval)? // When the first key went in (a burst's later keys come after it).
        if params["gesture"]?.stringValue == "plus", let pane = controller.content?.focusedPane {
            pane.stripModel.send(.newTab(after: nil))
            sent = .string("plus")
        } else if params["gesture"]?.stringValue == "mouse", case let .object(mouse)? = params["mouse"] {
            sent = DebugMouse.send(mouse.merging(["window": .string(controller.state.id)]) { own, _ in own }, services: services)
        } else if let agentClick {
            // A real click on the page's element (the chat header's buttons, a transcript line); the click's
            // instant is when its press goes in, not when the page's report after it comes back.
            sent = await DebugAgentPaneClick.click(agentClick.params, pane: agentClick.pane, view: agentClick.view, services: services,
                                                   located: agentClick.located) { firstSent = (BenchSpans.ms(.now - start), CACurrentMediaTime()) }
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
        let (frames, recorded) = await recording.result(sentAt: sentAt)
        let spans = BenchSpans.end()
        // `content: "rightmost"`: the content area is the rightmost pane's (a right-side open's pane, focused or not).
        let pane = params["content"]?.stringValue == "rightmost" ? controller.content?.rightmostPane : controller.content?.focusedPane
        guard let report = await window.frameStripReport(frames, sentAt: sentAt, sentTime: sentTime,
                                                         content: params["content"]?.stringValue == "none" || crop != nil ? nil : pane?.view.contentHost,
                                                         strip: crop != nil ? nil : pane?.view.stripView, tolerance: tolerance, jump: params["jump"]?.doubleValue, dir: dir),
              case .object(var fields)? = JSONValue(foundation: report)
        else { return .object(["error": .string("no frames"), "key": sent]) }
        fields["key"] = sent
        if case let .object(extra)? = JSONValue(foundation: recorded) { fields.merge(extra) { own, _ in own } }
        fields["spans"] = .array(spans.map { .object(["name": .string($0.name), "ms": .number(($0.start - sentAt).rounded()), "duration_ms": .number($0.milliseconds)]) })
        return .object(fields)
    }
}

extension WorkspaceContentController {
    /// The shown pane whose right edge is farthest right in the window (the right column's), for a frame strip of a
    /// right-side open that may leave the focus in the chat.
    var rightmostPane: PaneController? {
        layoutModel.screens.flatMap(\.layout.panes).compactMap { panes[$0] }
            .filter { $0.view.window != nil && !$0.view.isHiddenOrHasHiddenAncestor }
            .max { $0.view.convert($0.view.bounds, to: nil).maxX < $1.view.convert($1.view.bounds, to: nil).maxX }
    }
}
#endif
