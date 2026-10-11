#if DEBUG
import AppKit

/// `debug.app_activation {active: bool}` (DEBUG builds): what the app sees
/// when it resigns or becomes active, without activating it (a
/// `CMUX_NEXT_NO_ACTIVATE=1` run never takes the display). Resign posts
/// `willResignActive`, orders out every visible panel with
/// `hidesOnDeactivate` (the palette) and posts `didResignActive`; become
/// active posts `willBecomeActive`, orders those panels front again and
/// posts `didBecomeActive`, so every observer of the app's activation runs
/// as on a real Cmd-Tab back. `NSApp.isActive` stays false: a panel shown
/// again still does not take the keys. The layout-loop stress uses it for
/// the palette shown on app activation (Sentry CMUXTERM-MACOS-40Q3).
@MainActor
enum DebugAppActivation {
    /// Panels this verb ordered out, in their order, to show again.
    private static var hiddenPanels: [Weak] = []

    static func send(_ params: [String: JSONValue]) -> JSONValue {
        let active = params["active"]?.boolValue ?? true
        let app = NSApplication.shared
        let center = NotificationCenter.default
        if active {
            center.post(name: NSApplication.willBecomeActiveNotification, object: app)
            let panels = hiddenPanels.compactMap(\.window)
            hiddenPanels.removeAll()
            for panel in panels { panel.orderFront(nil) }
            center.post(name: NSApplication.didBecomeActiveNotification, object: app)
            return .object(["active": .bool(true), "shown_panels": .number(Double(panels.count))])
        }
        center.post(name: NSApplication.willResignActiveNotification, object: app)
        let panels = app.windows.filter { ($0 as? NSPanel)?.hidesOnDeactivate == true && $0.isVisible }
        hiddenPanels = panels.map(Weak.init)
        for panel in panels { panel.orderOut(nil) }
        center.post(name: NSApplication.didResignActiveNotification, object: app)
        return .object(["active": .bool(false), "hidden_panels": .number(Double(panels.count))])
    }

    private struct Weak {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }
}
#endif
