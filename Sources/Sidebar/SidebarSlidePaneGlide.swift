import AppKit
import Bonsplit
import WebKit
import QuartzCore

/// Per-pane motion for the toggle slide, on top of the content root's.
///
/// Each pane (its Bonsplit hosting view and its portal-hosted terminal or
/// browser views) glides so its leading edge runs from its hidden-layout x
/// to its docked x, and a mask narrows or widens it so its trailing edge
/// does the same. Neighbours meet at every frame and dividers land where
/// they end. Divider lines are drawn by the split views in the content
/// root's frame, so strips in their colour ride the gaps instead, and each
/// pane's trailing action buttons ride its trailing edge as a picture.
@MainActor
final class SidebarSlidePaneGlide {
    private(set) var animations: [SidebarSlideGlide.Layer] = []
    /// Each pane's tab bar with the width it is held at for the slide.
    private(set) var tabBarWidths: [(tabBar: BonsplitTabBarSlideWidthControlling, pane: NSView, held: CGFloat)] = []
    private(set) var overlay: NSView?
    private var masked: [CALayer] = []
    private var pictures: [CALayer] = []
    private var hidden: [(layer: CALayer, mask: CALayer?)] = []
    private var undrawn: [(layer: CALayer, contentsRect: CGRect)] = []

    /// Hides a view's own drawing (not its subviews) for the slide: a
    /// split view's divider is drawn at the hidden layout's x in its frame,
    /// and would show through a translucent terminal next to the strip that
    /// stands in for it.
    private func undraw(_ layer: CALayer) {
        undrawn.append((layer, layer.contentsRect))
        layer.contentsRect = .zero
    }

    /// Hides a view's drawing for the slide with an empty mask: AppKit owns
    /// a view layer's opacity and hidden state and resets them, and a
    /// portal re-adding the view drops its animations, but it leaves masks.
    private func hide(_ layer: CALayer) {
        hidden.append((layer, layer.mask))
        layer.mask = CALayer()
    }

    init?(
        reference: NSView,
        container: NSView,
        above: NSView,
        portalViews: [SidebarSlideStart.PortalView],
        hidden: SidebarSlidePaneLayout,
        docked: SidebarSlidePaneLayout,
        sidebarWidth: CGFloat,
        chrome: [ObjectIdentifier: [SidebarSlidePaneChrome.Band]],
        tabFades: [ObjectIdentifier: SidebarSlidePaneChrome.TabFade],
        tabRow: SidebarSlideTabRowCapture?
    ) {
        guard sidebarWidth > 0, !hidden.isEmpty else { return nil }
        let width = Double(sidebarWidth)
        func factor(_ hiddenX: CGFloat, _ dockedX: CGFloat) -> Double {
            SidebarSlideGlide.factor(hiddenLeading: hiddenX, dockedLeading: dockedX, sidebarWidth: sidebarWidth)
        }
        func rect(_ view: NSView) -> NSRect { reference.convert(view.bounds, from: view) }

        // Strips and pictures ride above everything that moves.
        let overlay = PictureLayerHostView(frame: container.convert(reference.bounds, from: reference))
        overlay.wantsLayer = true
        container.addSubview(overlay, positioned: .above, relativeTo: above)
        guard let overlayLayer = overlay.layer else {
            overlay.removeFromSuperview()
            return nil
        }
        self.overlay = overlay
        func addLayer(_ layer: CALayer, at frameInReference: NSRect) {
            let frame = overlay.convert(frameInReference, from: reference)
            layer.anchorPoint = .zero
            layer.position = frame.origin
            layer.bounds = CGRect(origin: .zero, size: frame.size)
            overlayLayer.addSublayer(layer)
        }

        // Each split slot moves with its own leading edge, relative to the
        // slot around it, and clips at its own trailing edge; a lone pane
        // only clips. Panes inside slots ride along.
        func absoluteFactor(_ id: ObjectIdentifier) -> Double {
            guard let hiddenRect = hidden.slots[id] ?? hidden.panes[id], let dockedRect = docked.slots[id] ?? docked.panes[id] else { return 0 }
            return factor(hiddenRect.minX, dockedRect.minX)
        }
        func enclosingSlot(_ view: NSView) -> ObjectIdentifier? {
            sequence(first: view.superview, next: { $0?.superview }).lazy.compactMap { $0 }
                .map(ObjectIdentifier.init).first { hidden.slots[$0] != nil }
        }
        var nodes = Array(hidden.slots.keys)
        nodes += hidden.panes.keys.filter { id in hidden.view(id).map { enclosingSlot($0) == nil } == true }
        for id in nodes {
            guard let view = hidden.view(id), let hiddenRect = hidden.slots[id] ?? hidden.panes[id],
                  let dockedRect = docked.slots[id] ?? docked.panes[id] else { continue }
            let parent = enclosingSlot(view).map(absoluteFactor) ?? 0
            glide(view, factor: absoluteFactor(id) - parent, frame: hiddenRect, widthChange: dockedRect.width - hiddenRect.width, sidebarWidth: width)
        }
        for (id, hiddenRect) in hidden.panes {
            guard let dockedRect = docked.panes[id], let pane = hidden.view(id) else { continue }
            func find(_ view: NSView) -> BonsplitTabBarSlideWidthControlling? {
                if let tabBar = view as? BonsplitTabBarSlideWidthControlling { return tabBar }
                return view.subviews.lazy.compactMap(find).first
            }
            guard let tabBar = find(pane) else { continue }
            let fade = tabFades[id] ?? SidebarSlidePaneChrome.TabFade()
            // At the pane's own (hidden, the wider) width: the tabs and their
            // scroll offset stay exactly as laid out, and nothing in them
            // reaches the pane's moving edge unfaded.
            tabBarWidths.append((tabBar, pane, hiddenRect.width))
            fadeTabRow(of: pane, tabBar: tabBar, fade: fade, trailing: Double(dockedRect.width - hiddenRect.width) / width)
        }
        // The portals' views (terminals, browser pages) follow the pane
        // their anchor sits in, by its absolute motion; neither portal is
        // inside a slot.
        var paneMotion: [(hidden: NSRect, docked: NSRect)] = []
        for (id, hiddenRect) in hidden.panes {
            if let dockedRect = docked.panes[id] { paneMotion.append((hiddenRect, dockedRect)) }
        }
        for portalView in portalViews {
            guard let id = hidden.pane(containing: portalView.anchor),
                  let hiddenRect = hidden.panes[id], let dockedRect = docked.panes[id] else { continue }
            let widthChange = dockedRect.width - hiddenRect.width
            let leading = factor(hiddenRect.minX, dockedRect.minX)
            glide(portalView.view, factor: leading, frame: rect(portalView.view), widthChange: widthChange, sidebarWidth: width)
            followContent(of: portalView.view, widthChange: widthChange, sidebarWidth: width)
        }
        for (id, split) in hidden.splits {
            guard let dockedSplit = docked.splits[id], let view = hidden.view(id) as? NSSplitView else { continue }
            // AppKit draws a layer-backed view into its layer or into a
            // content sublayer of its own (not a subview's).
            if let layer = view.layer {
                undraw(layer)
                (layer.sublayers ?? []).filter { !($0.delegate is NSView) }.forEach(undraw)
            }
            var color: CGColor?
            view.effectiveAppearance.performAsCurrentDrawingAppearance { color = view.dividerColor.cgColor }
            let strip = CALayer()
            strip.backgroundColor = color
#if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_SIDEBAR_SLIDE_STRIP_DEBUG"] != nil {
                strip.backgroundColor = NSColor.systemRed.cgColor
                SidebarNavigationTimings.record("slide.strip vertical=\(split.isVertical) hidden=\(split.rect) docked=\(dockedSplit.rect) gap=\(Self.divider(split))")
            }
#endif
            let gap = Self.divider(split)
            addLayer(strip, at: gap)
            if split.isVertical {
                animations.append(.init(layer: strip, keyPath: "transform.translation.x", factor: factor(gap.minX, Self.divider(dockedSplit).minX)))
            } else {
                animations.append(.init(layer: strip, keyPath: "transform.translation.x", factor: factor(split.rect.minX, dockedSplit.rect.minX)))
                animations.append(Self.width(strip, from: split.rect.width, to: dockedSplit.rect.width, sidebarWidth: width))
            }
        }
        // Each pane's trailing chrome rides its trailing edge, inside the
        // pane's own clip (its slot, or a lone pane itself), so a picture
        // can never leave its pane.
        for (id, bands) in chrome {
            guard let pane = hidden.view(id), let hiddenRect = hidden.panes[id], let dockedRect = docked.panes[id] else { continue }
            let clipId = enclosingSlot(pane) ?? id
            guard let clip = hidden.view(clipId), let clipLayer = clip.layer else { continue }
            let relative = factor(hiddenRect.maxX, dockedRect.maxX) - absoluteFactor(clipId)
            for band in bands {
                let picture = CALayer()
                picture.contents = band.image
                picture.contentsGravity = .resize
                picture.zPosition = 1_000
                picture.name = SidebarSlidePaneGlide.trailingPictureName
                picture.frame = clip.convert(band.rect, from: reference)
                clipLayer.addSublayer(picture)
                pictures.append(picture)
                animations.append(.init(layer: picture, keyPath: "transform.translation.x", factor: relative))
            }
        }
#if DEBUG
        SidebarNavigationTimings.record("slide.panes slots=\(hidden.slots.count) panes=\(paneMotion.map { "\($0.hidden.minX)-\($0.hidden.maxX)>\($0.docked.minX)-\($0.docked.maxX)" }) splits=\(hidden.splits.count) animations=\(animations.count) chrome=\(chrome.values.map(\.count))")
#endif
        // Minimal mode's leading tabs: ground and picture inside the
        // leading pane's clip.
        if let tabRow, let id = hidden.panes.first(where: { $0.value.insetBy(dx: -1, dy: -1).contains(NSPoint(x: tabRow.groundRect.minX + 1, y: tabRow.groundRect.midY)) })?.key,
           let pane = hidden.view(id) {
            let clipId = enclosingSlot(pane) ?? id
            if let clip = hidden.view(clipId), let clipLayer = clip.layer {
                let layers = tabRow.makeLayers(in: clip, from: reference)
                clipLayer.addSublayer(layers.ground)
                clipLayer.addSublayer(layers.picture)
                pictures += [layers.ground, layers.picture]
                animations.append(.init(layer: layers.picture, keyPath: "transform.translation.x", factor: tabRow.factor - absoluteFactor(clipId)))
            }
        }
        // Overlays painting at every pane's hidden-layout rect at once (the
        // terminal portal's divider, pane-swap and drop-zone overlays, the
        // tmux rings, a cloud failure card) can follow no single pane, and
        // are hidden for the slide.
        for view in Self.paneWideOverlays(in: container, portalViews: portalViews) {
            if let layer = view.layer { hide(layer) }
        }
    }

    /// The tabs hold still for the slide (laid out once at the pane's own
    /// width, `holdTabBars`), and are faded out before the pane's moving
    /// trailing edge as Bonsplit fades them at rest, by masks riding that
    /// edge on the slide's spring: no main-thread layout can lag it. The
    /// selected tab's indicator is faded the same way; the bar's bottom
    /// line ends at the lane, whose picture carries it on.
    private func fadeTabRow(of pane: NSView, tabBar: BonsplitTabBarSlideWidthControlling, fade: SidebarSlidePaneChrome.TabFade, trailing: Double) {
        let lane = tabBar.slideActionLaneWidth
        let views = SidebarSlidePaneChrome.tabRowViews(in: pane)
        for (view, isSelectionChrome) in views.scrollViews.map({ ($0, false) }) + views.selectionChromes.map({ ($0, true) }) {
            guard let layer = view.layer, layer.mask == nil else { continue }
            let edge = view.convertToLayer(view.convert(NSPoint(x: pane.bounds.maxX, y: 0), from: pane)).x
            var keep: (rows: ClosedRange<CGFloat>, edge: CGFloat)?
            if isSelectionChrome {
                let line = view.convertToLayer(NSRect(x: view.bounds.minX, y: view.isFlipped ? view.bounds.maxY - 1 : view.bounds.minY, width: view.bounds.width, height: 1))
                keep = (line.minY...line.maxY, edge - lane)
            }
            let mask = SidebarSlidePaneChrome.trailingFadeMask(for: layer, edge: edge, fade: fade.fade, occlusion: fade.occlusion, keep: keep)
            layer.mask = mask
            masked.append(layer)
            animations.append(.init(layer: mask, keyPath: "transform.translation.x", factor: trailing))
        }
    }

    /// Names the pictures that ride a pane's trailing edge (for checks).
    static let trailingPictureName = "cmux.slide.trailingPicture"

    /// Window-level views known to paint per-pane geometry across panes.
    static let paneWideOverlayIdentifiers: Set<String> = [
        "cmux.tmuxWorkspacePane.overlay.container",
        "cmux.cloudPaneCreationFailure.card",
    ]

    private static func paneWideOverlays(in container: NSView, portalViews: [SidebarSlideStart.PortalView]) -> [NSView] {
        let hosts = Set(portalViews.compactMap { $0.view.superview }.map(ObjectIdentifier.init))
        let portalOverlays = container.subviews.flatMap { host -> [NSView] in
            guard hosts.contains(ObjectIdentifier(host)) || host is WindowBrowserHostView else { return [] }
            let entries = Set(portalViews.map { ObjectIdentifier($0.view) })
            return host.subviews.filter { !entries.contains(ObjectIdentifier($0)) && !$0.isHidden }
        }
        let windowOverlays = container.subviews.filter { paneWideOverlayIdentifiers.contains($0.identifier?.rawValue ?? "") }
        return portalOverlays + windowOverlays
    }

    /// The divider gap between a split's two sides.
    private static func divider(_ split: SidebarSlidePaneLayout.Split) -> NSRect {
        if split.isVertical {
            let lead = min(split.first.maxX, split.second.maxX)
            return NSRect(x: lead, y: split.rect.minY, width: split.thickness, height: split.rect.height)
        }
        let top = split.first.minY < split.second.minY ? split.first : split.second
        return NSRect(x: split.rect.minX, y: top.maxY, width: split.rect.width, height: split.thickness)
    }

    private static func width(_ layer: CALayer, from: CGFloat, to: CGFloat, sidebarWidth: Double) -> SidebarSlideGlide.Layer {
        SidebarSlideGlide.Layer(layer: layer, keyPath: "bounds.size.width", factor: Double(to - from) / sidebarWidth, base: Double(from))
    }

    /// Moves `view` (laid out at `frame` in the hidden layout) by `factor`
    /// and clips it at a trailing edge that moves by `widthChange` over the
    /// slide.
    private func glide(_ view: NSView, factor: Double, frame: NSRect, widthChange: CGFloat, sidebarWidth width: Double) {
        guard let layer = view.layer else { return }
        if factor != 0 {
            animations.append(.init(layer: layer, keyPath: "transform.translation.x", factor: factor))
        }
        if let existing = layer.mask {
#if DEBUG
            SidebarNavigationTimings.record("slide.mask existing on \(NSStringFromClass(type(of: view)))")
#endif
            _ = existing
            return
        }
        let mask = CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        let bleed: CGFloat = 10_000
        mask.anchorPoint = .zero
        mask.position = CGPoint(x: layer.bounds.minX, y: layer.bounds.minY - bleed)
        mask.bounds = CGRect(x: 0, y: 0, width: frame.width, height: layer.bounds.height + 2 * bleed)
        layer.mask = mask
        masked.append(layer)
        animations.append(Self.width(mask, from: frame.width, to: frame.width + widthChange, sidebarWidth: width))
    }

    /// What a portal view (terminal, browser page) draws on top of its
    /// content keeps its own anchoring, found by geometry: AppKit pieces in
    /// its trailing half that hug its trailing edge (a scroller, a badge)
    /// follow that edge, centred ones its centre, and drawn overlays (find
    /// bars, rings, borders: any hosting or overlay view) are pictured and
    /// cut at a seam like the panes' chrome, both parts inside the view's
    /// own clip, the trailing part riding the trailing edge, while the live
    /// overlay is hidden for the slide.
    private func followContent(of view: NSView, widthChange: CGFloat, sidebarWidth width: Double) {
        let bounds = view.bounds
        let trailing = Double(widthChange) / width
        guard let host = view.layer else { return }
        func split(_ overlay: NSView) {
            guard let layer = overlay.layer, Self.mayDrawShapes(layer),
                  let rep = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) else { return }
            overlay.cacheDisplay(in: overlay.bounds, to: rep)
            // Nothing drawn, or nothing trailing: it rides with its view.
            guard Self.hasInk(rep) else { return }
            let bands = SidebarSlidePaneChrome.seams(in: rep)
            guard bands.contains(where: { $0.seam != nil }) else { return }
            let rect = view.convert(overlay.bounds, from: overlay)
            hide(layer)
            for band in bands {
                let seam = band.seam ?? rep.pixelsWide
                for (columns, factor) in [(0..<seam, 0.0), (seam..<rep.pixelsWide, trailing)] where !columns.isEmpty {
                    guard let part = SidebarSlidePaneChrome.picture(rep, rect: rect, rows: band.rows, columns: columns) else { continue }
                    let picture = CALayer()
                    picture.contents = part.image
                    picture.contentsGravity = .resize
                    picture.zPosition = 1_000
                    picture.name = factor == 0 ? nil : SidebarSlidePaneGlide.trailingPictureName
                    picture.frame = part.rect
                    host.addSublayer(picture)
                    pictures.append(picture)
                    if factor != 0 {
                        animations.append(.init(layer: picture, keyPath: "transform.translation.x", factor: factor))
                    }
                }
            }
        }
        func visit(_ parent: NSView) {
            for child in parent.subviews where !child.isHidden && child.alphaValue > 0 {
                let frame = view.convert(child.bounds, from: child)
                let name = NSStringFromClass(type(of: child))
                if frame.width < bounds.width * 0.6 {
                    guard let layer = child.layer else { continue }
                    if frame.minX >= bounds.midX, bounds.maxX - frame.maxX <= 48 {
                        animations.append(.init(layer: layer, keyPath: "transform.translation.x", factor: trailing))
                    } else if abs(frame.midX - bounds.midX) <= 4 {
                        animations.append(.init(layer: layer, keyPath: "transform.translation.x", factor: trailing / 2))
                    }
                } else if name.contains("HostingView") || name.contains("Overlay") {
                    split(child)
                } else {
                    visit(child)
                }
            }
        }
        visit(view)
    }

    /// Whether a layer tree may draw something with a shape (and so a
    /// trailing part): one that draws nothing (an idle ring, an empty host)
    /// or only flat fills (a dimming veil) has none. Known without
    /// rendering it.
    private static func mayDrawShapes(_ layer: CALayer) -> Bool {
        if layer.isHidden || layer.opacity == 0 { return false }
        if layer.contents != nil || layer.borderWidth > 0 { return true }
        if let shape = layer as? CAShapeLayer, shape.path != nil { return true }
        if layer is CATextLayer || layer is CAGradientLayer { return true }
        return (layer.sublayers ?? []).contains(where: mayDrawShapes)
    }

    /// Whether any sampled pixel has some opacity.
    private static func hasInk(_ rep: NSBitmapImageRep) -> Bool {
        guard rep.hasAlpha, let data = rep.bitmapData, rep.bitsPerPixel == 32 else { return true }
        let alphaMask: UInt32 = rep.bitmapFormat.contains(.alphaFirst) ? 0x0000_00FF : 0xFF00_0000
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            let row = UnsafeRawPointer(data + y * rep.bytesPerRow).assumingMemoryBound(to: UInt32.self)
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) where row[x] & alphaMask != 0 { return true }
        }
        return false
    }

    /// Holds every tab bar still for the slide at its held width (its lane
    /// hidden; the lane's picture rides the edge), or back at its pane's
    /// own width when done.
    func holdTabBars(_ hold: Bool = true) {
        for entry in tabBarWidths {
            entry.tabBar.slideTabBarWidth = hold ? entry.held : nil
        }
        // Apply now, inside this transaction, not on a later pass: SwiftUI
        // marks the hosting view for layout on its own schedule.
        for entry in tabBarWidths {
            entry.pane.needsLayout = true
            entry.pane.layoutSubtreeIfNeeded()
        }
    }

    func tearDown(animationKey: String) {
        holdTabBars(false)
        animations.forEach { $0.layer.removeAnimation(forKey: $0.animationKey(animationKey)) }
        masked.forEach { $0.mask = nil }
        hidden.forEach { $0.layer.mask = $0.mask }
        pictures.forEach { $0.removeFromSuperlayer() }
        undrawn.forEach { $0.layer.contentsRect = $0.contentsRect }
        overlay?.removeFromSuperview()
    }

    /// A layer host for the strips and pictures that takes no clicks and
    /// never repaints its layer.
    private final class PictureLayerHostView: NSView {
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() {}
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// What a slide needs from the layout on screen: the panes' rects, the
/// portals' views, and pictures of the panes' trailing chrome. A show takes
/// it all at the press; a hide takes the docked rects before its commit and
/// the rest from the hidden layout right after, which is what is live for
/// the whole slide.
@MainActor
struct SidebarSlideStart {
    /// A view a portal draws over a pane, with the anchor that places it.
    struct PortalView {
        let view: NSView
        let anchor: NSView
    }

    var tabRow: SidebarSlideTabRowCapture?
    var chrome: SidebarSlidePaneChrome?
    var docked: SidebarSlidePaneLayout?
    /// A show's start is the hidden layout itself.
    var hidden: SidebarSlidePaneLayout?

    /// DEBUG-only A/B switch (`CMUX_SIDEBAR_SLIDE_RIGID=1`): the old rigid
    /// slide, for measuring what per-pane motion costs.
    static let isRigid: Bool = {
#if DEBUG
        return ProcessInfo.processInfo.environment["CMUX_SIDEBAR_SLIDE_RIGID"] != nil
#else
        return false
#endif
    }()

    /// The docked layout, taken before a hide commits.
    static func dockedLayout(in window: NSWindow) -> SidebarSlidePaneLayout? {
        guard !isRigid, let reference = TerminalWindowPortalRegistry.portalsByWindowId[ObjectIdentifier(window)]?.installedReferenceView else { return nil }
        return SidebarSlidePaneLayout.measure(in: reference)
    }

    /// Everything else, from the layout live for the slide.
    static func capture(in window: NSWindow, docked: SidebarSlidePaneLayout?, inset: CGFloat, sidebarWidth: CGFloat, buttonCount: Int) -> Self {
        guard !isRigid, let reference = TerminalWindowPortalRegistry.portalsByWindowId[ObjectIdentifier(window)]?.installedReferenceView else { return Self() }
        let layout = SidebarSlidePaneLayout.measure(in: reference)
        // Content no picture can show (portal views, and web views a panel
        // hosts in the pane itself) is left out of the chrome strips.
        var covered = portalViews(in: window).map { reference.convert($0.view.bounds, from: $0.view) }.filter { $0.width > 1 }
        func findWebViews(_ view: NSView) {
            if view is WKWebView, !view.isHiddenOrHasHiddenAncestor {
                covered.append(reference.convert(view.bounds, from: view))
                return
            }
            view.subviews.forEach(findWebViews)
        }
        layout.panes.keys.compactMap(layout.view).forEach(findWebViews)
        return Self(
            tabRow: SidebarSlideTabRowCapture.capture(in: reference, docked: false, inset: inset, sidebarWidth: sidebarWidth),
            chrome: SidebarSlidePaneChrome.capture(in: reference, layout: layout, covered: covered, buttonCount: buttonCount),
            docked: docked,
            hidden: layout
        )
    }

    /// The terminal and browser views the portals show, from the portals'
    /// own entries (wherever each portal is installed).
    static func portalViews(in window: NSWindow) -> [PortalView] {
        var result: [PortalView] = []
        func add(_ view: NSView?, _ anchor: NSView?) {
            guard let view, let anchor, !view.isHiddenOrHasHiddenAncestor, view.alphaValue > 0, view.frame.width > 1 else { return }
            result.append(PortalView(view: view, anchor: anchor))
        }
        if let portal = TerminalWindowPortalRegistry.portalsByWindowId[ObjectIdentifier(window)] {
            portal.entriesByHostedId.values.forEach { add($0.hostedView, $0.anchorView) }
        }
        if let portal = BrowserWindowPortalRegistry.portalsByWindowId[ObjectIdentifier(window)] {
            portal.entriesByWebViewId.values.forEach { add($0.containerView, $0.anchorView) }
        }
        return result
    }
}
