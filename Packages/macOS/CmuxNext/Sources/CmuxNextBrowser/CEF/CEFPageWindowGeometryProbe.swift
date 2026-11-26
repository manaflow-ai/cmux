#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign

/// Debug and bench builds: each move or resize of a Chromium page window is a fact of the resize step it lands in, on
/// the step log (`page_window_geometry`, ``ResizeStepTimes/note(_:ms:step:detail:)``, written only while the log
/// streams). ``ChromiumWindowGuard`` passes on the windows' move and resize notices in these builds only. For an
/// in-tree page the window is the Browser's headless widget window, which the fork's `CmuxParentViewTracker` resizes on
/// a geometry update (`-updateDetached`: the widget's Views layout and its compositor's visibility), so the lines count
/// the tracker's updates per step: `open=1` while the step has not committed yet (the update ran inside cmux's layout
/// pass), `open=0` after its commit. `what=` names the notice (`resize`, `move`).
enum CEFPageWindowGeometryProbe {
    @MainActor static func windowMoved(_ window: NSWindow, resized: Bool) {
        guard isChromiumPageWindow(window) else { return }
        let open = ResizeStepTimes.openStep != nil
        ResizeStepTimes.note("page_window_geometry", ms: 0, detail: " open=\(open ? 1 : 0) what=\(resized ? "resize" : "move")")
    }

    /// A Chromium page window: an embedded `CefNSWindow`, or any Views widget window (`NativeWidgetMac*`, the
    /// headless one of an in-tree page included).
    static func isChromiumPageWindow(_ window: NSWindow) -> Bool {
        if ChromiumPageWindowVisibility.isEmbeddedPage(window) { return true }
        let name = NSStringFromClass(type(of: window))
        return name.hasPrefix("NativeWidgetMac") || name.hasPrefix("CefNSWindow")
    }
}
#endif
