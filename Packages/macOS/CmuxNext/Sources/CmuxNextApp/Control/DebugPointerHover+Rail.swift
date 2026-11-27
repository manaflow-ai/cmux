#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextSettings

// `debug.pointer_hover {rail: "top" | "middle" | "bottom" | index}`: the synthetic pointer goes to
// the middle of that mark's row on the thin sidebar rail (`sidebar.style` = rail), so a capture
// tour can show the rail's hover card at a real row without knowing the window's geometry.
extension DebugPointerHover {
    static func railPoint(_ params: [String: JSONValue], in window: NSWindow, services: AppServices) -> CGPoint? {
        guard let which = params["rail"]?.stringValue ?? params["rail"]?.intValue.map(String.init),
              let controller = services.windows.controllers.first(where: { $0.window === window }) else { return nil }
        return controller.sidebar.container.railView.rowCenterInWindow(which)
    }
}
#endif
