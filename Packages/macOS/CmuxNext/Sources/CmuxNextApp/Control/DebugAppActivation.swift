#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextSettings

/// `debug.app_activation {active: bool}` (DEBUG builds): what the app sees
/// when it resigns or becomes active, without activating it (a
/// `CMUX_NEXT_NO_ACTIVATE=1` run never takes the display). Resign posts
/// `willResignActive`, orders out every visible panel with
/// `hidesOnDeactivate` (the palette) and posts `didResignActive`; become
/// active posts `willBecomeActive`, shows those panels again (a child panel
/// goes back onto its parent window, as AppKit keeps it there) and posts
/// `didBecomeActive`, so every observer of the app's activation runs as on
/// a real Cmd-Tab back. `NSApp.isActive` stays false: a panel shown again
/// still does not take the keys. Refused while the app is really active, so
/// the synthetic notifications never reach the no-activate keyboard guard's
/// give-back path. The layout-loop stress uses it for the palette shown on
/// app activation (Sentry CMUXTERM-MACOS-40Q3).
///
/// `window_notices: true` also posts the main window's resign/become main and key notices, as a
/// real Cmd-Tab does. The reply's `observers_ms` is the main-thread time the become (or resign)
/// notices took to deliver, for scripts/cmux-next/activation-perf.py (the perf gate's
/// `activation` row).
@MainActor
enum DebugAppActivation {
    /// Panels this verb ordered out, with their parent windows, to show again.
    private static var hiddenPanels: [Hidden] = []

    static func send(_ params: [String: JSONValue]) -> JSONValue {
        let app = NSApplication.shared
        guard !app.isActive else {
            return .object(["error": .string("the app is really active; debug.app_activation only runs while it is inactive")])
        }
        let active = params["active"]?.boolValue ?? true
        let windowNotices = params["window_notices"]?.boolValue ?? false
        let center = NotificationCenter.default
        let window = windowNotices ? (app.mainWindow ?? app.windows.first { $0.isVisible && $0.canBecomeMain }) : nil
        let clock = ContinuousClock()
        let start = clock.now
        func elapsedMS() -> JSONValue { .number(Double((clock.now - start) / .microseconds(1)) / 1000) }
        if active {
            center.post(name: NSApplication.willBecomeActiveNotification, object: app)
            let hidden = hiddenPanels
            hiddenPanels.removeAll()
            var shown = 0
            for entry in hidden {
                guard let panel = entry.panel else { continue }
                shown += 1
                if let parent = entry.parent, parent.isVisible {
                    parent.addChildWindow(panel, ordered: .above)
                } else {
                    panel.orderFront(nil)
                }
            }
            center.post(name: NSApplication.didBecomeActiveNotification, object: app)
            if let window {
                center.post(name: NSWindow.didBecomeMainNotification, object: window)
                center.post(name: NSWindow.didBecomeKeyNotification, object: window)
            }
            return .object(["active": .bool(true), "shown_panels": .number(Double(shown)), "synthetic": .bool(true),
                            "observers_ms": elapsedMS()])
        }
        center.post(name: NSApplication.willResignActiveNotification, object: app)
        if let window {
            center.post(name: NSWindow.didResignKeyNotification, object: window)
            center.post(name: NSWindow.didResignMainNotification, object: window)
        }
        let panels = app.windows.filter { ($0 as? NSPanel)?.hidesOnDeactivate == true && $0.isVisible }
        hiddenPanels = panels.map { Hidden(panel: $0, parent: $0.parent) }
        for panel in panels { panel.orderOut(nil) }
        center.post(name: NSApplication.didResignActiveNotification, object: app)
        return .object(["active": .bool(false), "hidden_panels": .number(Double(panels.count)), "synthetic": .bool(true),
                        "observers_ms": elapsedMS()])
    }

    private struct Hidden {
        weak var panel: NSWindow?
        weak var parent: NSWindow?
    }
}
#endif
