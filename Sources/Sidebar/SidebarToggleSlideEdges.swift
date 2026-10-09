import AppKit
import QuartzCore

#if DEBUG
/// DEBUG-only per-frame pane geometry for checking the toggle's slide
/// without screenshots (`CMUX_SIDEBAR_SLIDE_EDGES=1` with
/// `CMUX_NAV_TIMINGS_LOG`): the presented leading and trailing x of every
/// pane and every portal-hosted view, clipped by the masks the slide puts
/// on them and their ancestors, in window points.
@MainActor
enum SidebarToggleSlideEdges {
    static let isEnabled = ProcessInfo.processInfo.environment["CMUX_SIDEBAR_SLIDE_EDGES"] != nil

    static func record(_ phase: String, window: NSWindow?) {
        guard isEnabled, let window,
              let reference = TerminalWindowPortalRegistry.portalsByWindowId[ObjectIdentifier(window)]?.installedReferenceView,
              let rootView = reference.superview, let rootLayer = rootView.layer else { return }
        // The landing reads the model: its commit replaced the motion, and
        // the presentation catches up only on the next frame.
        let presents = phase != "landed"
        func shown(_ layer: CALayer) -> CALayer { presents ? (layer.presentation() ?? layer) : layer }
        let root = shown(rootLayer)
        func span(_ view: NSView) -> String? {
            guard let layer = view.layer else { return nil }
            let presented = shown(layer)
            var rect = presented.convert(presented.bounds, to: root)
            var current: NSView? = view
            while let ancestor = current, ancestor !== rootView {
                if let ancestorLayer = ancestor.layer, let mask = ancestorLayer.mask {
                    // A mask's frame is in its layer's own coordinates.
                    let host = shown(ancestorLayer)
                    let clip = host.convert(shown(mask).frame, to: root)
                    let minX = max(rect.minX, clip.minX), maxX = min(rect.maxX, clip.maxX)
                    rect = NSRect(x: minX, y: rect.minY, width: max(0, maxX - minX), height: rect.height)
                }
                current = ancestor.superview
            }
            return String(format: "%.1f:%.1f", rect.minX, rect.maxX)
        }
        let layout = SidebarSlidePaneLayout.measure(in: reference)
        let panes = layout.panes.sorted { ($0.value.minY, $0.value.minX) < ($1.value.minY, $1.value.minX) }
            .compactMap { layout.view($0.key).flatMap(span) }
        let hosted = SidebarSlideStart.hostedViews(in: window)
            .filter { !$0.isHidden && $0.alphaValue > 0 && $0.frame.width > 1 && !NSStringFromClass(type(of: $0)).contains("Overlay") }
            .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
            .compactMap(span)
        SidebarNavigationTimings.record("slide.edges phase=\(phase) t=\(String(format: "%.4f", CACurrentMediaTime())) panes=\(panes.joined(separator: ",")) hosted=\(hosted.joined(separator: ","))")
    }
}
#endif
