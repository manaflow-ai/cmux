import AppKit
import QuartzCore

/// The layers a slide moves, plus what keeps an open right sidebar still.
///
/// The right sidebar lives in the moving content root. While a slide runs,
/// the root's layers that make up the right sidebar's column run the spring
/// backwards, so the live sidebar stays put on screen (a picture of it would
/// not match: `cacheDisplay` draws its text heavier than the screen does).
/// Everything else that could reach the column is masked off at its leading
/// edge, by masks that also run the spring backwards. The terminal reads as
/// sliding under the right sidebar, which never moves.
@MainActor
final class SidebarToggleSlideSession {
    private(set) var movingLayers: [CALayer]
    private(set) var masks: [CALayer] = []
    private(set) var glides: [SidebarSlideGlide.Layer] = []
    /// The right sidebar column's layers, held still against the root.
    private var stillLayers: [SidebarSlideGlide.Layer] = []
    /// The root's layers masked off at the column's edge.
    private var clipped: [CALayer] = []
    /// The right sidebar column's leading edge, in the content root's
    /// coordinates (nil without a right sidebar).
    private var stillEdge: CGFloat?
    private var tabRowOverlay: NSView?
    private var stillChrome: [NSView] = []
    private(set) var paneGlide: SidebarSlidePaneGlide?

    /// The panes' rects in both layouts, for per-pane motion.
    struct Panes {
        let hidden: SidebarSlidePaneLayout
        let docked: SidebarSlidePaneLayout
        let portalViews: [SidebarSlideStart.PortalView]
        let sidebarWidth: CGFloat
    }

    convenience init(
        views: [NSView],
        trailingStillWidth: CGFloat,
        sidebarWidth: CGFloat,
        titleGlide: SidebarSlideGlide.Layer?,
        tabRow: SidebarSlideTabRowCapture?,
        chrome: SidebarSlidePaneChrome?,
        panes: Panes?
    ) {
        self.init(views: views, trailingStillWidth: trailingStillWidth, sidebarWidth: sidebarWidth)
        glides = [titleGlide].compactMap { $0 } + stillLayers
        if let reference = views.first, let container = reference.superview, let last = views.last {
            // Each pane moves on its own; without that, the trailing-edge
            // panes' action buttons at least hold still.
            if let panes, let glide = SidebarSlidePaneGlide(
                reference: reference,
                container: container,
                above: last,
                portalViews: panes.portalViews,
                hidden: panes.hidden,
                docked: panes.docked,
                sidebarWidth: panes.sidebarWidth,
                chrome: chrome?.bands ?? [:],
                tabFades: chrome?.tabFades ?? [:],
                tabRow: tabRow
            ), let overlay = glide.overlay, let layer = overlay.layer {
                paneGlide = glide
                movingLayers.append(layer)
                clipAtStillEdge(overlay, reference: reference)
                glides.append(contentsOf: glide.animations)
                return
            } else {
                stillChrome = chrome?.makeStillOverlays(above: reference, in: container) ?? []
            }
        }
        // The tab row picture rides with the content root and glides inside it.
        if let tabRow, let reference = views.first, let container = reference.superview,
           let overlay = tabRow.makeOverlay(above: reference, in: container), let layer = overlay.view.layer {
            tabRowOverlay = overlay.view
            movingLayers.append(layer)
            clipAtStillEdge(overlay.view, reference: reference)
            glides.append(overlay.glide)
        }
    }

    private init(views: [NSView], trailingStillWidth: CGFloat, sidebarWidth: CGFloat) {
        movingLayers = views.compactMap(\.layer)
        guard trailingStillWidth > 0,
              let reference = views.first,
              let referenceLayer = reference.layer else { return }
        let edge = reference.bounds.maxX - trailingStillWidth
        stillEdge = edge
        // The root's own layers split at the column's edge: the column's run
        // the spring backwards (still and live), the rest that the slide can
        // carry into it are clipped. A layer across the edge (the window's
        // ground) keeps moving; it covers the column the whole way.
        let reach = 2 * sidebarWidth
        for layer in referenceLayer.sublayers ?? [] {
            let frame = layer.frame
            if frame.minX >= edge - 0.5 {
                let base = (layer.value(forKeyPath: "transform.translation.x") as? Double) ?? 0
                stillLayers.append(.init(layer: layer, keyPath: "transform.translation.x", factor: -1, base: base))
            } else if frame.maxX <= edge + 0.5, frame.maxX > edge - reach, layer.mask == nil {
                clip(layer, at: layer.convert(CGPoint(x: edge, y: 0), from: referenceLayer).x)
                clipped.append(layer)
            }
#if DEBUG
            if frame.minX < edge - 0.5, frame.maxX > edge + 0.5, layer.contents != nil || layer.sublayers?.isEmpty == false {
                SidebarNavigationTimings.record("slide.still across edge \(String(describing: type(of: layer))) \(frame)")
            }
#endif
        }
        views.dropFirst().forEach { clipAtStillEdge($0, reference: reference) }
    }

    /// Masks a moving view off at the right sidebar column's edge. The mask
    /// runs the slide's spring backwards, so the edge stays put on screen.
    private func clipAtStillEdge(_ view: NSView, reference: NSView) {
        guard let edge = stillEdge, let layer = view.layer else { return }
        clip(layer, at: view.convert(NSPoint(x: edge, y: 0), from: reference).x)
    }

    private func clip(_ layer: CALayer, at x: CGFloat) {
        let bleed: CGFloat = 10_000
        let mask = CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        mask.frame = CGRect(x: -bleed, y: -bleed, width: x + bleed, height: layer.bounds.height + 2 * bleed)
        layer.mask = mask
        masks.append(mask)
    }

    func tearDown(animationKey: String) {
        for layer in movingLayers {
            layer.removeAnimation(forKey: animationKey)
            layer.mask = nil
        }
        glides.forEach { $0.layer.removeAnimation(forKey: $0.animationKey(animationKey)) }
        paneGlide?.tearDown(animationKey: animationKey)
        clipped.forEach { $0.mask = nil }
        tabRowOverlay?.removeFromSuperview()
        stillChrome.forEach { $0.removeFromSuperview() }
    }
}
