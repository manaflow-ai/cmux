#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextBrowser
import CmuxNextSettings

/// `debug.omnibar_bench` (DEBUG builds): one click on the omnibar of a browser pane at rest,
/// through the app's real mouse path (`debug.mouse`: the event queue, `CmuxApplication.sendEvent`,
/// monitors, the window, AppKit's text tracking), timed to the display frame that shows it.
///
/// Params: `pane`, `window` (default: the focused browser pane of the first window), `blur`
/// (default true: the page takes the keyboard first, so the click focuses the omnibar from rest).
///
/// Reports, in ms after the click was posted:
/// - `attached_ms`: the first frame at which the omnibar edits (field editor attached, caret);
/// - `focused_ms`: the first frame at which the editing look (ring, fill) has fully shown;
/// - `selected_ms`: the first frame at which its whole text is selected (Chrome's first click);
/// - `frames_to_focused`: display frames from the click to `focused_ms` (1 = the next frame);
/// - `spans`: the main-thread spans and marks of the press (`BenchSpans`, the omnibar's probe).
@MainActor
enum DebugOmnibarClickBench {
    private static let frames = BenchFrames()

    static func run(_ params: [String: JSONValue], _ services: AppServices?) async -> JSONValue {
        guard let services else { return .null }
        guard let bar = DebugOmnibar.addressBar(params, services: services), let window = bar.window,
              let controller = services.windows.controllers.first(where: { $0.window === window }) else {
            return .object(["error": .string("no browser pane")])
        }
        if params["blur"]?.boolValue != false, bar.isEditing {
            // Escape reverts typed text, then returns the keyboard to the page.
            for _ in 0..<3 where bar.isEditing {
                _ = DebugKey.send(["key": .string("escape"), "window": .string(controller.state.id)], services: services)
                frames.start()
                _ = await frames.settled(until: { !bar.isEditing }, start: .now, window: 0, deadline: 500)
                _ = frames.stop()
            }
        }
        guard !bar.isEditing else { return .object(["error": .string("the omnibar still edits; it cannot be clicked from rest")]) }
        // Quiet frames first, so the click starts from an idle main thread.
        frames.start()
        _ = await frames.settled(until: { true }, start: .now, window: 120, deadline: 1_000)
        _ = frames.stop()

        // A Chromium page has the keyboard in its own child window: the click then also moves key.
        let keyBefore = NSApp.keyWindow.map { $0 === window ? "shell" : String(describing: type(of: $0)) } ?? "none"
        let field = bar.debugFieldFrameInWindow
        let point = InputJournal.topLeftPoint(NSPoint(x: field.midX, y: field.midY), in: window, relativeTo: window)
        frames.start()
        BenchSpans.begin()
        // `debug.timings` `omnibar_clicks`: as a palette open, input_ms is the mouse-down's age when
        // the field took focus and key_to_frame_ms runs to the commit of that frame's transaction.
        let engine = bar.allowsChromiumSchemes ? "chromium" : "webkit"
        var timed = false
        bar.benchProbe = { name in
            BenchSpans.mark(name)
            guard !timed, name == "field.becameFirstResponder",
                  let down = NSApp.currentEvent, down.type == .leftMouseDown else { return }
            timed = true
            let pressed = down.timestamp
            let input = (ProcessInfo.processInfo.systemUptime - pressed) * 1_000
            CATransaction.setCompletionBlock {
                let frame = (ProcessInfo.processInfo.systemUptime - pressed) * 1_000
                // The times are taken here; only the record hops to the main actor.
                Task { @MainActor in DebugTimings.omnibarClicked(engine: engine, input: input, keyToFrame: frame) }
            }
        }
        defer { bar.benchProbe = nil }
        let start = ContinuousClock.now
        let posted = DebugMouse.send(["action": .string("click"), "x": .number(point.x), "y": .number(point.y),
                                      "window": .string(controller.state.id)], services: services)
        // One check per display tick for all three, so each time is the tick that first showed it
        // (awaited one after another, each could only resolve on a later tick than the one before).
        var attached: Double?, selected: Double?, focused: Double?
        var ticks: [Double] = []
        _ = await frames.settled(until: {
            let now = BenchSpans.ms(.now - start)
            ticks.append(now)
            if attached == nil, bar.isEditing { attached = now }
            if selected == nil, bar.isEditing, bar.debugAllSelected { selected = now }
            if focused == nil, bar.debugShowsEditing { focused = now }
            return attached != nil && selected != nil && focused != nil
        }, start: start, window: 0, deadline: 2_000)
        let spans = BenchSpans.end()
        let stats = frames.stop()
        // The press as the app ran it: dispatch (`app.sendEvent.down` start) to its end, which
        // includes AppKit's text tracking through the release posted with it.
        let press = spans.first { $0.name == "app.sendEvent.down" }
        let pressEnd = press.map { $0.start + $0.milliseconds }
        /// Display ticks after the press ended, up to and including the one at `shown` (1: the next frame).
        func framesAfterPress(_ shown: Double?) -> JSONValue {
            guard let shown, let pressEnd else { return .null }
            return .number(Double(ticks.filter { $0 > pressEnd && $0 <= shown }.count))
        }
        func fromDispatch(_ shown: Double?) -> JSONValue {
            guard let shown, let press else { return .null }
            return .number(shown - press.start)
        }
        var refresh = 1_000.0 / 60
        if case .object(let fields) = stats, let value = fields["refresh_ms"]?.doubleValue, value > 0 { refresh = value }
        let snapshot = bar.debugSnapshot
        return .object([
            "engine": .string(engine),
            "posted": posted,
            "app_active": .bool(NSApp.isActive),
            "key_window_before": .string(keyBefore),
            "key_window_after": .string(NSApp.keyWindow.map { $0 === window ? "shell" : String(describing: type(of: $0)) } ?? "none"),
            "attached_ms": attached.map { .number($0) } ?? .null,
            "focused_ms": focused.map { .number($0) } ?? .null,
            "selected_ms": selected.map { .number($0) } ?? .null,
            "press_ms": press.map { .number($0.milliseconds) } ?? .null,
            "dispatch_ms": press.map { .number($0.start) } ?? .null,
            "attached_frames_after_press": framesAfterPress(attached),
            "selected_frames_after_press": framesAfterPress(selected),
            "focused_frames_after_press": framesAfterPress(focused),
            "dispatch_to_attached_ms": fromDispatch(attached),
            "dispatch_to_selected_ms": fromDispatch(selected),
            "dispatch_to_focused_ms": fromDispatch(focused),
            "frames_to_focused": focused.map { .number(($0 / refresh).rounded(.up)) } ?? .null,
            "main_thread_spans_ms": .number(spans.filter { $0.name.hasPrefix("app.sendEvent") }.reduce(0) { $0 + $1.milliseconds }),
            "spans": .array(spans.map { .object(["name": .string($0.name), "at": .number($0.start), "ms": .number($0.milliseconds)]) }),
            "frames": stats,
            "phase": .string(snapshot.phase),
            "field_selection": snapshot.fieldSelection.map { .array([.number(Double($0.location)), .number(Double($0.length))]) } ?? .null,
            "field_text_length": .number(Double((snapshot.fieldText as NSString).length)),
        ])
    }
}
#endif
