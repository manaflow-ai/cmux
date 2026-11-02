#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextSettings

// `debug.pointer_hover {rail: "top" | "middle" | "bottom" | index}` (or `{usageWarning: true}`, below): the synthetic pointer goes to
// the middle of that mark's row on the thin sidebar rail (`sidebar.style` = rail), so a capture
// tour can show the rail's hover card at a real row without knowing the window's geometry.
extension DebugPointerHover {
    static func railPoint(_ params: [String: JSONValue], in window: NSWindow, services: AppServices) -> CGPoint? {
        guard let which = params["rail"]?.stringValue ?? params["rail"]?.intValue.map(String.init),
              let controller = services.windows.controllers.first(where: { $0.window === window }) else { return nil }
        return controller.sidebar.container.railView.rowCenterInWindow(which)
    }

    /// `debug.pointer_hover {usageWarning: true}`: the synthetic pointer goes to the topmost shown
    /// usage warning badge on a workspace row, so a capture tour shows its tooltip.
    static func usageWarningPoint(_ params: [String: JSONValue], in window: NSWindow, services: AppServices) -> CGPoint? {
        guard params["usageWarning"]?.boolValue == true,
              let controller = services.windows.controllers.first(where: { $0.window === window }) else { return nil }
        return controller.sidebar.container.sidebarView.debugUsageWarningCenterInWindow()
    }
}
#endif
