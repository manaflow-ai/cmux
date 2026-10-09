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

    private static var frameCount = 0

    /// DEBUG-only (`CMUX_SIDEBAR_SLIDE_LAYER_DUMP=<frame>`): every layer's
    /// presented frame in window points at that frame of each slide, for
    /// finding what draws where it should not.
    static func dumpLayers(window: NSWindow?) {
        guard let raw = ProcessInfo.processInfo.environment["CMUX_SIDEBAR_SLIDE_LAYER_DUMP"], let target = Int(raw),
              let window, let rootView = window.contentView?.superview, let rootLayer = rootView.layer else { return }
        frameCount += 1
        guard frameCount == target else { return }
        let root = rootLayer.presentation() ?? rootLayer
        var lines: [String] = []
        func visit(_ layer: CALayer, depth: Int) {
            let presented = layer.presentation() ?? layer
            let frame = presented.convert(presented.bounds, to: root)
            let owner = (layer.delegate as? NSView).map { String(NSStringFromClass(type(of: $0)).suffix(48)) } ?? String(describing: type(of: layer))
            if frame.width > 0, frame.height > 0, !layer.isHidden, presented.opacity > 0 {
                lines.append(String(repeating: " ", count: min(depth, 30)) + String(format: "%@ x=%.1f..%.1f y=%.1f..%.1f%@%@", owner, frame.minX, frame.maxX, frame.minY, frame.maxY, layer.mask != nil ? " masked" : "", layer.contents != nil ? " contents" : ""))
            }
            (layer.sublayers ?? []).forEach { visit($0, depth: depth + 1) }
        }
        visit(rootLayer, depth: 0)
        SidebarNavigationTimings.record("slide.layers\n" + lines.joined(separator: "\n"))
    }

    static func resetDump() { frameCount = 0 }

    static func record(_ phase: String, window: NSWindow?) {
        guard isEnabled, let window,
              let reference = TerminalWindowPortalRegistry.portalsByWindowId[ObjectIdentifier(window)]?.installedReferenceView,
              let rootView = reference.superview, let rootLayer = rootView.layer else { return }
        // The landing reads the model: its commit replaced the motion, and
        // the presentation catches up only on the next frame.
        let presents = phase != "landed"
        func shown(_ layer: CALayer) -> CALayer { presents ? (layer.presentation() ?? layer) : layer }
        let root = shown(rootLayer)
        func onScreen(_ view: NSView) -> NSRect? {
            // The nearest view with a layer carries the motion.
            guard let host = sequence(first: view, next: { $0.superview }).first(where: { $0.layer != nil }),
                  let layer = host.layer else { return nil }
            let presented = shown(layer)
            let local = host.convert(view.bounds, from: view)
            var rect = presented.convert(local, to: root)
            var current: NSView? = host
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
            return rect
        }
        func span(_ view: NSView) -> String? {
            onScreen(view).map { String(format: "%.1f:%.1f", $0.minX, $0.maxX) }
        }
        func box(_ rect: NSRect) -> String {
            String(format: "%.1f:%.1f:%.1f:%.1f", rect.minX, rect.maxX, rect.minY, rect.maxY)
        }
        let layout = SidebarSlidePaneLayout.measure(in: reference)
        let panes = layout.panes.sorted { ($0.value.minY, $0.value.minX) < ($1.value.minY, $1.value.minX) }
            .compactMap { layout.view($0.key).flatMap(span) }
        let hosted = SidebarSlideStart.portalViews(in: window).map(\.view)
            .compactMap { onScreen($0) }
            .sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
            .map { String(format: "%.1f:%.1f", $0.minX, $0.maxX) }
        // Tabs (live), and the pictures the slide shows (none may sit on a
        // live tab).
        var chips: [NSRect] = []
        func findTabs(_ view: NSView) {
            if SidebarSlideTabRowCapture.isTabItemRegion(view), !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty,
               let rect = onScreen(view) {
                chips.append(rect)
            }
            view.subviews.forEach(findTabs)
        }
        findTabs(reference)
        chips.sort { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        var pictures: [NSRect] = []
        func findPictures(_ layer: CALayer) {
            if layer.name == SidebarSlidePaneGlide.trailingPictureName {
                let presented = shown(layer)
                pictures.append(presented.convert(presented.bounds, to: root))
            }
            (layer.sublayers ?? []).forEach(findPictures)
        }
        findPictures(rootLayer)
        pictures.sort { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        SidebarNavigationTimings.record("slide.edges phase=\(phase) t=\(String(format: "%.4f", CACurrentMediaTime())) panes=\(panes.joined(separator: ",")) hosted=\(hosted.joined(separator: ",")) chips=\(chips.map(box).joined(separator: ",")) pics=\(pictures.map(box).joined(separator: ","))")
    }
}
#endif
