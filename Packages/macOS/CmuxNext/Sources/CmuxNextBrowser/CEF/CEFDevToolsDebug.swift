#if DEBUG || CMUX_BENCH_HOOKS
import AppKit

/// A Chromium tab's docked DevTools for live checks (`debug.cef.devtools_layout`):
/// open state, dock side, the sizes, and the divider's grab area and the
/// DevTools frame in window coordinates (points from the window's top left,
/// as `debug.mouse` takes them), with the window's number.
public struct CEFDevToolsDebug {
    let tab: CEFTab

    public init(_ tab: CEFTab) {
        self.tab = tab
    }

    public var report: [String: Any] {
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
        // The view a click at the grab's center reaches, and its superviews up to the content view.
        let center = container.convert(CGPoint(x: frames.grab.midX, y: frames.grab.midY), to: nil)
        if let frameView = window.contentView?.superview, let hit = frameView.hitTest(frameView.convert(center, from: nil)) {
            report["grab_hit"] = sequence(first: hit, next: \.superview).prefix(6).map { String(describing: type(of: $0)) }
        }
        report["divider_frame"] = topLeft(divider.frame)
        report["window_key"] = window.isKeyWindow
        report["container_subviews"] = container.subviews.map { String(describing: type(of: $0)) }
        report["window_frame"] = [window.frame.minX, window.frame.minY, window.frame.width, window.frame.height].map { Double($0) }
        return report
    }
}
#endif
