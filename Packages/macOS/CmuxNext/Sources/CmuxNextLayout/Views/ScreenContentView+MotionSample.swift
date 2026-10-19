#if DEBUG
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
    /// it (its frame cut by its reveal rect and its strip clip) in window points with a top-left
    /// origin and `z` its index among this screen's subviews (higher draws in front); each divider
    /// as `[id, x, y, width, height, alpha, z]`; and `zoom`, the pane a zoom or unzoom moves (or "").
    /// Covered panes (a zoom's leaving ones) are listed too. Hidden screens report nothing.
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
            if let host = subview as? PaneHostView {
                var visible = host.revealRect.map(host.frame.intersection) ?? host.frame
                if let mask = host.layer?.mask { visible = visible.intersection(mask.frame.offsetBy(dx: host.frame.minX, dy: host.frame.minY)) }
                let rect = visible.isNull ? CGRect.zero : visible
                let row: [Any] = [host.pane.rawValue as Any] + topLeft(rect, in: screen).map { $0 as Any } + [Double(host.alphaValue) as Any, index as Any]
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
