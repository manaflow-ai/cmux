#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign

extension ScreenContentView {
    private static var samplerRegistered = false

    /// Adds `motionSample` to `debug.motion`'s trace samplers, once.
    static func registerMotionSampler() {
        guard !samplerRegistered else { return }
        samplerRegistered = true
        MotionDebug.registeredSamplers.append(motionSample)
    }

    /// `debug.motion` `trace_*` sampler (registered by `LayoutRootView`): per display frame, each
    /// shown pane host as `[pane, x, y, width, height, alpha, z]`, where the rect is what shows of
    /// it (its frame cut by its strip clip) in window points with a top-left
    /// origin and `z` its index among this screen's subviews (higher draws in front); each divider
    /// as `[id, x, y, width, height, alpha, z]`; and `zoom`, the pane a zoom or unzoom moves (or "").
    /// Covered panes (a zoom's leaving ones) are listed too. Hidden screens report nothing.
    /// Each pane row goes on with what its content is laid out at: the host's frame
    /// `[fx, fy, fwidth, fheight]` (window points, top-left origin), the content view's size
    /// `[cwidth, cheight]`, and `header`, the share of the content's header (its tab strip)
    /// that shows (1: all of it; 0 without a header), then the content view in the window
    /// `[cx, cy, cwidth, cheight]`.
    static func motionSample(_ view: NSView) -> [String: [Any]]? {
        guard let screen = view as? ScreenContentView else { return nil }
        guard let window = screen.window, !screen.isHiddenOrHasHiddenAncestor else { return [:] }
        let height = window.frame.height
        func topLeft(_ rect: CGRect, in view: NSView) -> [Double] {
            let shown = view.convert(rect, to: nil)
            return [shown.minX, height - shown.maxY, shown.width, shown.height].map { (Double($0) * 100).rounded() / 100 }
        }
        var panes: [Any] = [], dividers: [Any] = []
        for (index, subview) in screen.subviews.enumerated() {
            if let host = subview as? PaneHostView, !host.isHidden {
                var visible = host.frame
                if let mask = host.layer?.mask { visible = visible.intersection(mask.frame.offsetBy(dx: host.frame.minX, dy: host.frame.minY)) }
                let rect = visible.isNull ? CGRect.zero : visible
                let header = CGRect(x: host.frame.minX + host.contentRect.minX, y: host.frame.minY + host.contentRect.minY,
                                    width: host.contentRect.width, height: host.headerHeight)
                let shownHeader = header.intersection(rect)
                let headerShare = header.width * header.height > 0 && !shownHeader.isNull
                    ? Double(shownHeader.width * shownHeader.height / (header.width * header.height)) : 0
                let laidOut = topLeft(host.frame, in: screen) + [Double(host.content.frame.width), Double(host.content.frame.height), (headerShare * 1000).rounded() / 1000]
                    + topLeft(host.content.bounds, in: host.content)
                let row: [Any] = [host.pane.rawValue as Any] + topLeft(rect, in: screen).map { $0 as Any } + [Double(host.alphaValue) as Any, index as Any]
                    + laidOut.map { $0 as Any }
                panes.append(row)
            } else if let divider = subview as? DividerHandleView, !divider.isHidden {
                let row: [Any] = [divider.kind.mouseAreaID as Any] + topLeft(divider.frame, in: screen).map { $0 as Any } + [Double(divider.alphaValue) as Any, index as Any]
                dividers.append(row)
            }
        }
        return ["panes": panes, "dividers": dividers, "zoom": [screen.zoomMotion.pane?.rawValue ?? ""]]
    }
}
#endif
