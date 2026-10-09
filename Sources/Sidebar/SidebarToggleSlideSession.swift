import AppKit
import QuartzCore

/// The layers a slide moves, plus what keeps an open right sidebar still.
///
/// The right sidebar lives in the moving content root. While a slide runs,
/// every moving layer is masked off at the right sidebar's leading edge (the
/// mask runs the same spring backwards, so the edge stays put on screen) and
/// a snapshot of the column is shown in its place, above everything. The
/// terminal reads as sliding under the right sidebar, which never moves.
@MainActor
final class SidebarToggleSlideSession {
    private(set) var movingLayers: [CALayer]
    let masks: [CALayer]
    private(set) var glides: [SidebarSlideGlide.Layer] = []
    private let stillOverlay: NSView?
    private var tabRowOverlay: NSView?
    private var stillChrome: [NSView] = []
    private(set) var paneGlide: SidebarSlidePaneGlide?
    private var tabBarDriver: SidebarSlideTabBarDriver?

    /// Lays the panes' tab bars out at the slide's progress every frame
    /// (`progress` maps a presentation time to 0 hidden ... 1 docked).
    func driveTabBars(from view: NSView, progress: @escaping (CFTimeInterval) -> Double?) {
        tabBarDriver?.stop()
        guard let paneGlide, !paneGlide.tabBarWidths.isEmpty else { return }
        paneGlide.layOutTabBars(progress: progress(CACurrentMediaTime()))
        tabBarDriver = SidebarSlideTabBarDriver(view: view) { [weak paneGlide] time in
            guard let paneGlide, let value = progress(time) else { return }
            paneGlide.layOutTabBars(progress: value)
        }
    }

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
        titleGlide: SidebarSlideGlide.Layer?,
        tabRow: SidebarSlideTabRowCapture?,
        chrome: SidebarSlidePaneChrome?,
        panes: Panes?
    ) {
        self.init(views: views, trailingStillWidth: trailingStillWidth)
        glides = [titleGlide].compactMap { $0 }
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
                tabRow: tabRow
            ), let layer = glide.overlay?.layer {
                paneGlide = glide
                movingLayers.append(layer)
                glides.append(contentsOf: glide.animations)
                return
            } else {
                stillChrome = chrome?.makeStillOverlays(above: reference, in: container) ?? []
            }
        }
        // The tab row picture rides with the content root (below the right
        // sidebar's still snapshot) and glides inside it.
        if let tabRow, let reference = views.first, let container = reference.superview,
           let overlay = tabRow.makeOverlay(above: reference, in: container), let layer = overlay.view.layer {
            tabRowOverlay = overlay.view
            movingLayers.append(layer)
            glides.append(overlay.glide)
        }
    }

    private init(views: [NSView], trailingStillWidth: CGFloat) {
        movingLayers = views.compactMap(\.layer)
        guard trailingStillWidth > 0,
              let reference = views.first,
              let container = reference.superview else {
            masks = []
            stillOverlay = nil
            return
        }
        let stillRect = NSRect(
            x: reference.bounds.maxX - trailingStillWidth,
            y: reference.bounds.minY,
            width: trailingStillWidth,
            height: reference.bounds.height
        )
        if let rep = reference.bitmapImageRepForCachingDisplay(in: stillRect) {
            reference.cacheDisplay(in: stillRect, to: rep)
            let overlay = NSView(frame: container.convert(stillRect, from: reference))
            overlay.wantsLayer = true
            overlay.layer?.contents = rep.cgImage
            overlay.layer?.contentsGravity = .resize
            container.addSubview(overlay, positioned: .above, relativeTo: nil)
            stillOverlay = overlay
        } else {
            stillOverlay = nil
        }
        let bleed: CGFloat = 10_000
        var masks: [CALayer] = []
        for view in views {
            guard let layer = view.layer else { continue }
            let edge = view.convert(NSPoint(x: stillRect.minX, y: 0), from: reference).x
            let mask = CALayer()
            mask.backgroundColor = NSColor.black.cgColor
            mask.frame = CGRect(x: -bleed, y: -bleed, width: edge + bleed, height: layer.bounds.height + 2 * bleed)
            layer.mask = mask
            masks.append(mask)
        }
        self.masks = masks
    }

    func tearDown(animationKey: String) {
        for layer in movingLayers {
            layer.removeAnimation(forKey: animationKey)
            layer.mask = nil
        }
        glides.forEach { $0.layer.removeAnimation(forKey: animationKey) }
        tabBarDriver?.stop()
        tabBarDriver = nil
        paneGlide?.tearDown(animationKey: animationKey)
        tabRowOverlay?.removeFromSuperview()
        stillChrome.forEach { $0.removeFromSuperview() }
        stillOverlay?.removeFromSuperview()
    }
}

/// A display link that hands each frame's presentation time to `tick`.
/// The tab bars re-lay out on the main thread, once per frame, only while
/// a slide runs.
@MainActor
private final class SidebarSlideTabBarDriver: NSObject {
    private var link: CADisplayLink?
    private let tick: (CFTimeInterval) -> Void

    init(view: NSView, tick: @escaping (CFTimeInterval) -> Void) {
        self.tick = tick
        super.init()
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

#if DEBUG
    private var costs: [Double] = []
#endif

    @objc private func step(_ link: CADisplayLink) {
#if DEBUG
        let began = CACurrentMediaTime()
        tick(link.targetTimestamp)
        costs.append((CACurrentMediaTime() - began) * 1000)
#else
        tick(link.targetTimestamp)
#endif
    }

    func stop() {
        link?.invalidate()
        link = nil
#if DEBUG
        if !costs.isEmpty {
            SidebarNavigationTimings.record(String(format: "slide.tabbarCost frames=%d avgMs=%.2f maxMs=%.2f", costs.count, costs.reduce(0, +) / Double(costs.count), costs.max() ?? 0))
        }
#endif
    }
}
