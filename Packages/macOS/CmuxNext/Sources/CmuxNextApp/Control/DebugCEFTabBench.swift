#if DEBUG
import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextSettings

/// `debug.new_tab {action: "bench_browser"}` (DEBUG builds): a new Chromium tab in the focused
/// pane of window `window`, from the input to the tab on screen and to its page's first pixels
/// (perf-lead issue 1, PL-cef-tab; `scripts/cmux-next/cef-tab-bench.py`).
///
/// `via`: `key` (default) sends Cmd-Shift-L, New Browser Tab, through the real key path
/// (`debug.key`); `action` runs action `id` (default `openBrowser`) as a person's run, with `url`
/// when given (a link opened in a new tab; `openBrowser.webkit` for a WebKit tab).
///
/// Per run, in ms after the input:
/// - `key_ms`: the input's synchronous main-thread time;
/// - `visible_ms`: the first display frame at which the pane shows another tab, selected in its
///   strip, whose browser view is in the pane (its themed content area is on screen);
/// - `page_ms`: the first display frame after that tab's page painted content (Blink's first
///   contentful paint, or its load finished);
/// - `spans`: main-thread spans and marks (`BenchSpans`, `CEFBenchMarks`: `cef.create_window`,
///   `cef.tab_add`, `cef.window_created`, `cef.spare_taken`, `cef.first_paint`);
/// - `spare_before`: the spare Chromium window's state before the input.
@MainActor
enum DebugCEFTabBench {
    private static let frames = BenchFrames()

    static func run(_ params: [String: JSONValue], _ controller: WindowController, _ services: AppServices) async -> JSONValue {
        guard let pane = controller.content?.focusedPane else { return .object(["error": .string("no focused pane")]) }
        let before = pane.currentTabKey
        let spare = services.cache.cef.spareWindowState
        var seen: Set<String> = []
        frames.start()
        BenchSpans.begin()
        CEFBenchMarks.shared.arm { name, milliseconds in BenchSpans.record(name, milliseconds: milliseconds) }
        defer { CEFBenchMarks.shared.arm(nil) }
        let start = ContinuousClock.now
        if params["via"]?.stringValue == "action" {
            // A person's action run (a link in a new tab, the palette's New WebKit Tab).
            let arguments = params["url"]?.stringValue.map { ["url": ActionValue.string($0)] } ?? [:]
            _ = services.registry.perform(ActionID(rawValue: params["id"]?.stringValue ?? "openBrowser"), invocation: ActionInvocation(arguments: arguments))
        } else {
            _ = DebugKey.send(["key": .string("l"), "modifiers": .array([.string("command"), .string("shift")]),
                               "window": .string(controller.state.id)], services: services)
        }
        let keyMilliseconds = BenchSpans.ms(.now - start)
        let shownEntry: () -> BrowserEntry? = {
            guard let key = pane.currentTabKey, key != before, pane.stripModel.selectedID?.rawValue == key,
                  pane.view.stripView.presentedTabIDs.contains(where: { $0.rawValue == key }),
                  pane.view.hostsContent, case .browser(let entry) = pane.currentContent else { return nil }
            seen.insert(key)
            seen.insert(entry.tab.id.rawValue)
            return entry
        }
        let visible = await frames.settled(until: { shownEntry() != nil }, start: start, window: 0, deadline: 5_000)
        let page = visible == nil ? nil : await frames.settled(until: {
            guard let entry = shownEntry() else { return false }
            if seen.contains(where: { CEFBenchMarks.shared.firstPaints[$0] != nil }) { return true }
            if case .finished = entry.tab.state.phase { return true }
            return false
        }, start: start, window: 0, deadline: 5_000)
        let spans = BenchSpans.end()
        let stats = frames.stop()
        return .object([
            "via": .string(params["via"]?.stringValue ?? "key"),
            "id": params["id"] ?? .null,
            "engine": .string(pane.currentContent.flatMap { content in
                if case .browser(let entry) = content { return entry.tab.engineKind == .cef ? "cef" : "webkit" }
                return nil
            } ?? "none"),
            "spare_before": .string(spare),
            "spare_after": .string(services.cache.cef.spareWindowState),
            "key_ms": .number(keyMilliseconds),
            "visible_ms": visible.map { .number($0) } ?? .null,
            "page_ms": page.map { .number($0) } ?? .null,
            "main_thread_spans_ms": .number(spans.reduce(0) { $0 + $1.milliseconds }),
            "spans": .array(spans.map { .object(["name": .string($0.name), "at": .number($0.start), "ms": .number($0.milliseconds)]) }),
            "frames": stats,
        ])
    }
}
#endif
