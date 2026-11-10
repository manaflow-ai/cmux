#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextControl

/// `debug.open_panel_bench` (DEBUG builds): one file-picker open as a click runs it (Home's "+", an agent
/// composer's Attach), timed to the display frame that shows the sheet, then cancelled.
///
/// Params: `mode` — `made` (default: the app's path, ``MadeAheadOpenPanel``: its warm-up first, then a new panel
/// for the open, as Home's "+" takes it), `fresh` (a bare `NSOpenPanel()` per open, with no warm-up before it) or
/// `window` (`begin(completionHandler:)`, a separate panel window instead of a sheet); `window` (default: the
/// first window). Reports `made_ahead_before` (the process's first panel was paid before this open),
/// `live_panels_before` (the app's panels alive before it: 0 at rest), `directory` (the folder the panel shows)
/// and, in ms from the click: `init_ms` (getting the panel: `NSOpenPanel()`),
/// `begin_ms` (the `beginSheetModal` / `begin` call), `sync_ms` (both: the click's main-thread time),
/// `visible_ms` (the first display frame with the panel on screen), `frames` (the display-link intervals
/// from 120 ms before the click until 300 ms after it showed: `max_ms` is the longest the main thread held a frame;
/// a call that runs a nested run loop, as `beginSheetModal` does while the sheet animates, keeps it near one frame).
@MainActor
enum DebugOpenPanelBench {
    private static let frames = BenchFrames()

    static func run(_ params: [String: JSONValue], _ services: AppServices?) async -> JSONValue {
        guard let services else { return .null }
        let mode = params["mode"]?.stringValue ?? "made"
        guard let window = services.windows.controllers.first?.window else { return .object(["error": .string("no window")]) }
        guard window.attachedSheet == nil else { return .object(["error": .string("the window already shows a sheet")]) }
        let shared = services.openPanel
        if mode == "made", !shared.isWarm {
            shared.warmWhenIdle()
            frames.start()
            _ = await frames.settled(until: { shared.isWarm || !shared.isWarming }, start: .now, window: 0, deadline: 8_000)
            _ = frames.stop()
        }
        let (madeBefore, liveBefore) = (shared.isWarm, shared.livePanels)
        // Quiet frames first, so the click starts from an idle main thread, and the display link keeps ticking into
        // the click: a stall of the click's own main-thread work then shows as one long frame interval (frames.max_ms),
        // while a nested run loop (a sheet animating inside the call) keeps the frames coming.
        frames.start()
        _ = await frames.settled(until: { true }, start: .now, window: 120, deadline: 1_000)
        let start = ContinuousClock.now
        guard let panel = mode == "fresh" || mode == "window" ? NSOpenPanel() : shared.panel() else {
            _ = frames.stop()
            return .object(["mode": .string(mode), "error": .string("the panel came back dead (no prompt)")])
        }
        let made = ContinuousClock.now
        if mode == "window" {
            panel.begin { _ in _ = panel.urls } // the handler holds its panel, as each real caller's does
        } else {
            panel.beginSheetModal(for: window) { _ in _ = panel.urls }
        }
        let begun = ContinuousClock.now
        let visible = await frames.settled(until: {
            panel.isVisible && panel.occlusionState.contains(.visible) && (mode == "window" || window.attachedSheet === panel)
        }, start: start, window: 300, deadline: 10_000)
        let stats = frames.stop()
        if mode == "window" {
            panel.cancel(nil)
        } else {
            window.endSheet(panel, returnCode: .cancel)
        }
        frames.start()
        _ = await frames.settled(until: { !panel.isVisible && window.attachedSheet == nil }, start: .now, window: 0, deadline: 3_000)
        _ = frames.stop()
        return .object([
            "mode": .string(mode),
            "made_ahead_before": .bool(madeBefore), "live_panels_before": .number(Double(liveBefore)),
            "prompt_nil": .bool(panel.prompt == nil), "directory": .string(panel.directoryURL?.path ?? ""),
            "init_ms": .number(BenchSpans.ms(made - start)),
            "begin_ms": .number(BenchSpans.ms(begun - made)),
            "sync_ms": .number(BenchSpans.ms(begun - start)),
            "visible_ms": visible.map { .number($0) } ?? .null,
            "frames": stats,
        ])
    }
}
#endif
