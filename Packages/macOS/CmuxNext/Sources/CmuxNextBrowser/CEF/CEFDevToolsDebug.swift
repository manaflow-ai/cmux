#if DEBUG
import AppKit

/// A Chromium tab's docked DevTools for live checks (`debug.cef.devtools_layout`):
/// open state, dock side, the sizes, and the divider's grab area and the
/// DevTools frame in window coordinates (points from the window's top left,
/// as `debug.mouse` takes them), with the window's number.
public enum CEFDevToolsDebug {
    public static func report(_ tab: CEFTab) -> [String: Any] {
        let controller = tab.devToolsController
        var report: [String: Any] = [
            "open": tab.devTools.isOpen,
            "dock": controller.layout.dock.rawValue,
            "bottom_fraction": controller.layout.bottomFraction,
            "right_fraction": controller.layout.rightFraction,
            "docked_views": controller.views != nil,
        ]
        let container = tab.container
        guard let window = container.window, let divider = controller.views?.divider, !divider.isHidden else { return report }
        let height = window.contentView?.bounds.height ?? window.frame.height
        func topLeft(_ rect: CGRect) -> [Double] {
            let inWindow = container.convert(rect, to: nil)
            return [inWindow.minX, height - inWindow.maxY, inWindow.width, inWindow.height].map { Double($0) }
        }
        let frames = controller.frames(in: container.bounds)
        report["grab"] = topLeft(frames.grab)
        report["devtools_frame"] = topLeft(frames.devTools)
        report["page_frame"] = topLeft(frames.page)
        report["window_number"] = window.windowNumber
        report["content_height"] = Double(height)
        report["window_frame"] = [window.frame.minX, window.frame.minY, window.frame.width, window.frame.height].map { Double($0) }
        return report
    }
}
#endif
