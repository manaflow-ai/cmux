#if DEBUG
import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextTabs
import CmuxNextWakeups

/// `debug.new_tab {action: "frame_strip"}` (DEBUG builds): the window as the
/// window server composited it, frame after frame, around one key sent
/// through the real key path (`key`, default `n`, with Command: Cmd-N; `t`
/// for Cmd-T). Frames are read off the main actor back to back for
/// `duration_ms` (default 700) after the key, and some before it.
///
/// The check is DESIGN P1 (two layers, two rules). CONTENT, the content area
/// of the focused pane (its `contentHost` below the tab strip, which is chrome;
/// `content: "none"` for a split,
/// where every pane's content is clipped chrome), changes in one step: each
/// frame equals the one before the key or the last one there
/// (`content_intermediate` counts the others), and it is never blank, one
/// flat color that was not there before the key (`blank`). CHROME, the rest
/// of the window, moves continuously: each frame's `progress` (0 = before,
/// 1 = final, from the share of pixels that differ from each) never goes
/// back (`reversals`: a spring that passes its target and returns, which
/// only a bounce may do), never leaps (`max_step`, the largest progress
/// between two frames; `jumps` counts steps over `jump`, default 0.6, from a
/// frame that had not yet moved), and `moving` counts the frames between
/// before and final (0 when the change applied in one step). `modifiers`
/// (default ["command"]) and `key` choose the gesture: `d` is Cmd-D, `d`
/// with ["command","shift"] Cmd-Shift-D, `w` closes; `gesture: "plus"`
/// presses the focused strip's + (its intent) instead of a key. `content: "panes"`
/// (splits) leaves every pane's content area, before the key and at the
/// end, out of the chrome counts, so a new terminal painting its prompt is
/// not read as motion; only pane chrome, tab bars and dividers count. A pixel counts as
/// changed past `tolerance` (default 0.0005 of the counted pixels). Tab motion is judged from
/// the strip's own `tabs.travel` samples while `debug.motion` records (`tabs_moving_frames`,
/// `tabs_restarts`: a second motion in one gesture, `tabs_peak_travel`). PNGs of every frame
/// and one strip (`strip.png`, the frames side by side) go to `dir`.
@MainActor
enum DebugFrameStrip {
    typealias Frame = FrameStripFrame

    static func run(_ params: [String: JSONValue], _ controller: WindowController, _ services: AppServices) async -> JSONValue {
        guard let window = controller.window, window.windowNumber > 0 else { return .object(["error": .string("no window")]) }
        let number = CGWindowID(window.windowNumber)
        let scale = params["scale"]?.doubleValue ?? 0.25
        let duration = params["duration_ms"]?.doubleValue ?? 700
        let tolerance = params["tolerance"]?.doubleValue ?? 0.0005
        let dir = params["dir"]?.stringValue ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("frame-strip-\(UUID().uuidString)")
        // The app's bench marks around the key come back with the frames (`spans`, ms from the key).
        BenchSpans.begin()
        let start = ContinuousClock.now
        let recording = Task.detached { await FrameStripRecorder(window: number, scale: scale).record(from: start, until: 120 + duration) }
        // The key goes in once the recorder has frames from before it.
        let lead = DemandTimer(owner: "debug.frame_strip.lead")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            lead.schedule(after: .milliseconds(120)) { @MainActor in done.resume() }
        }
        let panesMode = params["content"]?.stringValue == "panes"
        let panesBefore = panesMode ? paneContentRects(controller, window: window) : []
        let modifiers = params["modifiers"] ?? .array([.string("command")])
        let sent: JSONValue
        if params["gesture"]?.stringValue == "plus", let pane = controller.content?.focusedPane {
            // The strip's + button: the same intent its press sends.
            pane.stripModel.send(.newTab(after: nil))
            sent = .string("plus")
        } else if params["gesture"]?.stringValue == "drag_new", let pane = controller.content?.focusedPane {
            sent = await dragWhileNewTab(pane, services)
        } else {
            sent = DebugKey.send(["key": .string(params["key"]?.stringValue ?? "n"), "modifiers": modifiers,
                                  "window": .string(controller.state.id)], services: services)
        }
        let sentAt = BenchSpans.ms(.now - start), sentTime = CACurrentMediaTime()
        let frames = await recording.value
        let spans = BenchSpans.end()
        guard let first = frames.first, let last = frames.last, let before = frames.last(where: { $0.milliseconds < sentAt }) else {
            return .object(["error": .string("no frames"), "key": sent])
        }
        let content = params["content"]?.stringValue == "none" || panesMode ? nil : contentRect(controller, window: window, frame: first)
        // Splits: every pane's content (before and after) is out of the chrome counts.
        let paneRects = panesMode ? (panesBefore + paneContentRects(controller, window: window)).map { scaled($0, window: window, frame: first) } : []
        let excluded = content.map { [$0] } ?? paneRects
        let jump = params["jump"]?.doubleValue ?? 0.6
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var rows: [JSONValue] = []
        var intermediate = 0, blank = 0, contentIntermediate = 0, moving = 0, reversals = 0, jumps = 0
        var previous: Double?, maxStep = 0.0, peak = 0.0
        for (index, frame) in frames.enumerated() where frame.milliseconds >= before.milliseconds {
            let outsideBefore = frame.difference(from: before, excluding: excluded)
            let outsideFinal = frame.difference(from: last, excluding: excluded)
            let isIntermediate = outsideBefore > tolerance && outsideFinal > tolerance
            // Chrome progress from before (0) to final (1).
            let progress = outsideBefore + outsideFinal > 0 ? outsideBefore / (outsideBefore + outsideFinal) : (outsideBefore > 0 ? 1 : 0)
            if let previous {
                let step = progress - previous
                maxStep = max(maxStep, step)
                if step > jump, previous < 0.05 { jumps += 1 }
                // A frame going back toward "before" after the chrome got further: a reversal.
                if progress < peak - 0.05 { reversals += 1 }
            }
            peak = max(peak, progress)
            previous = progress
            // The content area is the before frame or the final one, nothing in between.
            let contentChanged = content.map { frame.difference(from: before, within: $0) > tolerance && frame.difference(from: last, within: $0) > tolerance } ?? false
            // Flat, and not still the content from before the key (an empty terminal is flat too).
            let isBlank = content.map { frame.flatness(in: $0) > 0.995 && frame.difference(from: before, within: $0) > tolerance } ?? false
            if isIntermediate { intermediate += 1; moving += 1 }
            if contentChanged { contentIntermediate += 1 }
            if isBlank { blank += 1 }
            let name = String(format: "frame-%03d.png", index)
            frame.writePNG(to: (dir as NSString).appendingPathComponent(name))
            rows.append(.object([
                "ms": .number((frame.milliseconds - sentAt).rounded()), "file": .string(name),
                "outside_vs_before": .number(outsideBefore), "outside_vs_final": .number(outsideFinal),
                "progress": .number((progress * 1000).rounded() / 1000),
                "intermediate": .bool(isIntermediate), "content_intermediate": .bool(contentChanged), "blank": .bool(isBlank),
            ]))
        }
        frames.filter { $0.milliseconds >= before.milliseconds }.writeStrip(to: (dir as NSString).appendingPathComponent("strip.png"))
        // Tab motion from the strip's own travel (`debug.motion` recording): pixels cannot judge a sliding cell.
        let tabs = MotionTravelSummary("tabs.travel", after: sentTime)
        return .object([
            "key": sent, "dir": .string(dir), "frames": .array(rows), "intermediate": .number(Double(intermediate)),
            "moving": .number(Double(moving)), "reversals": .number(Double(reversals)), "jumps": .number(Double(jumps)),
            "max_step": .number((maxStep * 1000).rounded() / 1000), "content_intermediate": .number(Double(contentIntermediate)),
            "blank": .number(Double(blank)), "frame_count": .number(Double(rows.count)),
            "tabs_moving_frames": .number(Double(tabs.movingFrames)), "tabs_restarts": .number(Double(tabs.restarts)),
            "tabs_peak_travel": .number(tabs.peak.rounded()),
            "spans": .array(spans.map { .object(["name": .string($0.name), "ms": .number(($0.start - sentAt).rounded()), "duration_ms": .number($0.milliseconds)]) }),
            "mean_interval_ms": .number(frames.count > 1 ? (last.milliseconds - first.milliseconds) / Double(frames.count - 1) : 0),
        ])
    }

    /// `gesture: "drag_new"`: drags the focused strip's first tab right in 12 steps, one per frame
    /// (synthetic events into the strip's own handlers), and at step 4 a script opens a terminal tab
    /// in the pane (`newSurface` with the CLI's origin): the drag's springs must keep running.
    private static func dragWhileNewTab(_ pane: PaneController, _ services: AppServices) async -> JSONValue {
        let strip = pane.view.stripView
        guard let window = strip.window, let id = strip.displayedOrder.first, let start = strip.tabCenterInWindow(id) else {
            return .string("drag_new: no tab")
        }
        func send(_ type: NSEvent.EventType, _ dx: CGFloat) {
            guard let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: start.x + dx, y: start.y), modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            else { return }
            switch type {
            case .leftMouseDown: strip.mouseDown(with: event)
            case .leftMouseUp: strip.mouseUp(with: event)
            default: strip.mouseDragged(with: event)
            }
        }
        send(.leftMouseDown, 0)
        for step in 1...12 {
            let tick = DemandTimer(owner: "debug.frame_strip.drag")
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in tick.schedule(after: .milliseconds(16)) { @MainActor in done.resume() } }
            send(.leftMouseDragged, CGFloat(step) * 18)
            if step == 4 {
                _ = services.registry.perform("newSurface", invocation: ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.paneKey), origin: .cli))
            }
        }
        send(.leftMouseUp, 12 * 18)
        return .string("drag_new")
    }

    /// The focused pane's content area in `frame` pixels (top-left origin), once the key opened its page.
    private static func contentRect(_ controller: WindowController, window: NSWindow, frame: Frame) -> CGRect? {
        guard let pane = controller.content?.focusedPane, let rect = contentArea(pane, window: window),
              let windowHeight = window.contentView?.superview?.bounds.height ?? window.contentView?.bounds.height
        else { return nil }
        let sx = Double(frame.width) / window.frame.width, sy = Double(frame.height) / windowHeight
        return CGRect(x: rect.minX * sx, y: (windowHeight - rect.maxY) * sy, width: rect.width * sx, height: rect.height * sy)
    }

    /// Every pane's content area in window coordinates (bottom-left origin).
    private static func paneContentRects(_ controller: WindowController, window: NSWindow) -> [CGRect] {
        (controller.content?.panes.values.map { $0 } ?? []).compactMap { contentArea($0, window: window) }
    }

    /// `pane`'s content host below its tab strip (window coordinates): the strip is chrome and
    /// counts as chrome, so only the host area under it is the content rect.
    private static func contentArea(_ pane: PaneController, window: NSWindow) -> CGRect? {
        let host = pane.view.contentHost, strip = pane.view.stripView
        guard host.window === window else { return nil }
        var rect = host.convert(host.bounds, to: nil)
        if strip.window === window, !strip.isHiddenOrHasHiddenAncestor {
            let band = strip.convert(strip.bounds, to: nil)
            if band.intersects(rect) { rect.size.height = max(0, min(rect.maxY, band.minY) - rect.minY) }
        }
        return rect
    }

    /// A window rect in `frame` pixels (top-left origin).
    private static func scaled(_ rect: CGRect, window: NSWindow, frame: Frame) -> CGRect {
        let windowHeight = window.contentView?.superview?.bounds.height ?? window.contentView?.bounds.height ?? window.frame.height
        let sx = Double(frame.width) / window.frame.width, sy = Double(frame.height) / windowHeight
        return CGRect(x: rect.minX * sx, y: (windowHeight - rect.maxY) * sy, width: rect.width * sx, height: rect.height * sy)
    }

}
#endif
