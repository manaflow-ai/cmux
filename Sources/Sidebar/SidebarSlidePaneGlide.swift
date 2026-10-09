import AppKit
import QuartzCore

/// Where Bonsplit's panes and split views sit, in the content root's
/// coordinates, for one layout (docked or hidden).
///
/// Bonsplit keeps split ratios, so the hidden layout's panes are wider in
/// proportion and every pane edge but the leading one rests elsewhere than
/// the docked edge shifted by the sidebar width.
@MainActor
struct SidebarSlidePaneLayout {
    struct Split {
        let rect: NSRect
        let first: NSRect
        let second: NSRect
        let isVertical: Bool
        let thickness: CGFloat
    }

    private(set) var panes: [ObjectIdentifier: NSRect] = [:]
    private(set) var splits: [ObjectIdentifier: Split] = [:]
    /// Each side of each split (a Bonsplit slot), which carries everything
    /// drawn inside it.
    private(set) var slots: [ObjectIdentifier: NSRect] = [:]
    private var views: [ObjectIdentifier: WeakView] = [:]

    private struct WeakView {
        weak var view: NSView?
    }

    func view(_ id: ObjectIdentifier) -> NSView? { views[id]?.view }

    var isEmpty: Bool { panes.isEmpty }

    static func measure(in reference: NSView) -> Self {
        var layout = Self()
        func rect(_ view: NSView) -> NSRect { reference.convert(view.bounds, from: view) }
        func walk(_ view: NSView) {
            // Hidden workspaces stay mounted at zero opacity.
            guard !view.isHidden, view.alphaValue > 0, (view.layer?.opacity ?? 1) > 0 else { return }
            let id = ObjectIdentifier(view)
            if SidebarSlideTabRowCapture.isSplitSlot(view) {
                layout.slots[id] = rect(view)
                layout.views[id] = WeakView(view: view)
            }
            if let split = splitView(view) {
                let slots = split.arrangedSubviews
                layout.splits[id] = Split(
                    rect: rect(split),
                    first: rect(slots[0]),
                    second: rect(slots[1]),
                    isVertical: split.isVertical,
                    thickness: max(split.dividerThickness, 1)
                )
                layout.views[id] = WeakView(view: split)
            } else if isLeaf(view) {
                layout.panes[id] = rect(view)
                layout.views[id] = WeakView(view: view)
                return
            }
            view.subviews.forEach(walk)
        }
        walk(reference)
        return layout
    }

    /// A Bonsplit split view: two sides, each a split slot.
    static func splitView(_ view: NSView) -> NSSplitView? {
        guard let split = view as? NSSplitView, split.arrangedSubviews.count == 2,
              split.arrangedSubviews.allSatisfy(SidebarSlideTabRowCapture.isSplitSlot) else { return nil }
        return split
    }

    /// A pane's own hosting view: in a split slot, or a lone pane, and not
    /// itself holding a further split.
    private static func isLeaf(_ view: NSView) -> Bool {
        let inSlot = view.superview.map(SidebarSlideTabRowCapture.isSplitSlot) == true
        guard inSlot || NSStringFromClass(type(of: view)).contains("PaneContainerView") else { return false }
        func holdsSplit(_ view: NSView) -> Bool {
            view.subviews.contains { splitView($0) != nil || holdsSplit($0) }
        }
        return !holdsSplit(view)
    }

    /// The same panes, rect for rect, within half a point.
    func matches(_ other: Self) -> Bool {
        func close(_ a: NSRect, _ b: NSRect) -> Bool {
            abs(a.minX - b.minX) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.height - b.height) < 0.5
        }
        guard panes.count == other.panes.count, splits.count == other.splits.count else { return false }
        return panes.allSatisfy { id, rect in other.panes[id].map { close($0, rect) } == true }
    }

    /// The docked layout predicted from this (hidden) one by Bonsplit's
    /// rule: the root loses the sidebar width at its leading edge, and each
    /// vertical split puts its divider at the pixel-rounded fraction of its
    /// available width. Used when no docked layout was seen for this one.
    func predictedDocked(in reference: NSView, sidebarWidth: CGFloat) -> Self {
        var docked = Self()
        docked.views = views
        let scale = reference.window?.backingScaleFactor ?? 2
        func rect(_ view: NSView) -> NSRect { reference.convert(view.bounds, from: view) }
        func assign(_ view: NSView, hiddenSlot: NSRect, dockedSlot: NSRect) {
            let id = ObjectIdentifier(view)
            let own = rect(view)
            let mapped = NSRect(
                x: own.minX - hiddenSlot.minX + dockedSlot.minX,
                y: own.minY,
                width: own.width - (hiddenSlot.width - dockedSlot.width),
                height: own.height
            )
            if panes[id] != nil {
                docked.panes[id] = mapped
                return
            }
            if slots[id] != nil {
                docked.slots[id] = mapped
            }
            if let split = splits[id], let splitView = Self.splitView(view) {
                var first = NSRect(x: mapped.minX, y: split.first.minY, width: mapped.width, height: split.first.height)
                var second = NSRect(x: mapped.minX, y: split.second.minY, width: mapped.width, height: split.second.height)
                if split.isVertical {
                    let available = split.rect.width - split.thickness
                    let fraction = available > 0 ? split.first.width / available : 0.5
                    let position = ((mapped.width - split.thickness) * fraction * scale).rounded() / scale
                    first.size.width = position
                    second.origin.x = mapped.minX + position + split.thickness
                    second.size.width = max(0, mapped.maxX - second.minX)
                }
                docked.splits[id] = Split(rect: mapped, first: first, second: second, isVertical: split.isVertical, thickness: split.thickness)
                let slots = splitView.arrangedSubviews
                assign(slots[0], hiddenSlot: rect(slots[0]), dockedSlot: first)
                assign(slots[1], hiddenSlot: rect(slots[1]), dockedSlot: second)
                return
            }
            for subview in view.subviews where !subview.isHidden {
                assign(subview, hiddenSlot: own, dockedSlot: mapped)
            }
        }
        func roots(_ view: NSView) {
            guard !view.isHidden else { return }
            let id = ObjectIdentifier(view)
            if panes[id] != nil || splits[id] != nil {
                let own = rect(view)
                assign(view, hiddenSlot: own, dockedSlot: NSRect(x: own.minX + sidebarWidth, y: own.minY, width: own.width - sidebarWidth, height: own.height))
                return
            }
            view.subviews.forEach(roots)
        }
        roots(reference)
        return docked
    }
}

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
    private(set) var overlay: NSView?
    private var masked: [CALayer] = []

    init?(
        reference: NSView,
        container: NSView,
        above: NSView,
        hostedViews: [NSView],
        hidden: SidebarSlidePaneLayout,
        docked: SidebarSlidePaneLayout,
        sidebarWidth: CGFloat,
        lanes: [ObjectIdentifier: (image: CGImage, rect: NSRect)]
    ) {
        guard sidebarWidth > 0, !hidden.isEmpty else { return nil }
        let width = Double(sidebarWidth)
        func factor(_ hiddenX: CGFloat, _ dockedX: CGFloat) -> Double {
            SidebarSlideGlide.factor(hiddenLeading: hiddenX, dockedLeading: dockedX, sidebarWidth: sidebarWidth)
        }
        func rect(_ view: NSView) -> NSRect { reference.convert(view.bounds, from: view) }

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
        // The hosted views follow their pane's absolute motion.
        var paneMotion: [(hidden: NSRect, docked: NSRect)] = []
        for (id, hiddenRect) in hidden.panes {
            if let dockedRect = docked.panes[id] { paneMotion.append((hiddenRect, dockedRect)) }
        }
        for view in hostedViews where !view.isHidden && view.alphaValue > 0
            && !NSStringFromClass(type(of: view)).contains("Overlay") {
            let frame = rect(view)
            guard frame.width > 1, let motion = paneMotion.first(where: { $0.hidden.contains(NSPoint(x: frame.midX, y: frame.midY)) }) else { continue }
            glide(view, factor: factor(motion.hidden.minX, motion.docked.minX), frame: frame, widthChange: motion.docked.width - motion.hidden.width, sidebarWidth: width)
        }
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
        for (id, split) in hidden.splits {
            guard let dockedSplit = docked.splits[id], let view = hidden.view(id) as? NSSplitView else { continue }
            var color: CGColor?
            view.effectiveAppearance.performAsCurrentDrawingAppearance { color = view.dividerColor.cgColor }
            let strip = CALayer()
            strip.backgroundColor = color
            let gap = Self.divider(split)
            addLayer(strip, at: gap)
            if split.isVertical {
                animations.append(.init(layer: strip, keyPath: "transform.translation.x", factor: factor(gap.minX, Self.divider(dockedSplit).minX)))
            } else {
                animations.append(.init(layer: strip, keyPath: "transform.translation.x", factor: factor(split.rect.minX, dockedSplit.rect.minX)))
                animations.append(Self.width(strip, from: split.rect.width, to: dockedSplit.rect.width, sidebarWidth: width))
            }
        }
        for (id, lane) in lanes {
            guard let hiddenRect = hidden.panes[id], let dockedRect = docked.panes[id] else { continue }
            let picture = CALayer()
            picture.contents = lane.image
            picture.contentsGravity = .resize
            let laneWidth = lane.rect.width
            addLayer(picture, at: NSRect(x: hiddenRect.maxX - laneWidth, y: lane.rect.minY, width: laneWidth, height: lane.rect.height))
            animations.append(.init(layer: picture, keyPath: "transform.translation.x", factor: factor(hiddenRect.maxX, dockedRect.maxX)))
        }
#if DEBUG
        SidebarNavigationTimings.record("slide.panes slots=\(hidden.slots.count) panes=\(paneMotion.map { "\($0.hidden.minX)-\($0.hidden.maxX)>\($0.docked.minX)-\($0.docked.maxX)" }) splits=\(hidden.splits.count) animations=\(animations.count) lanes=\(lanes.count)")
#endif
        // The portal's own divider overlay draws at the hidden layout's
        // dividers; the strips stand in for it until the landing.
        // An animation, not the model value: AppKit owns a view layer's
        // opacity and would put it back on the next display pass.
        for view in hostedViews where NSStringFromClass(type(of: view)).contains("SplitDividerOverlayView") {
            guard let layer = view.layer else { continue }
            animations.append(.init(layer: layer, keyPath: "opacity", factor: 0, base: 0))
        }
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
        guard layer.mask == nil else { return }
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

    func tearDown(animationKey: String) {
        animations.forEach { $0.layer.removeAnimation(forKey: animationKey) }
        masked.forEach { $0.mask = nil }
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

/// What a slide needs from the layout on screen at the press: pictures of
/// the tab bars, and on a hide (taken before the hidden layout commits) the
/// docked panes' rects.
@MainActor
struct SidebarSlideStart {
    var tabRow: SidebarSlideTabRowCapture?
    var lanes: SidebarSlideTrailingChromeCapture?
    var docked: SidebarSlidePaneLayout?

    static func capture(in window: NSWindow, docked: Bool, inset: CGFloat, sidebarWidth: CGFloat, buttonCount: Int) -> Self {
        guard let reference = TerminalWindowPortalRegistry.portalsByWindowId[ObjectIdentifier(window)]?.installedReferenceView else { return Self() }
        return Self(
            tabRow: SidebarSlideTabRowCapture.capture(in: reference, docked: docked, inset: inset, sidebarWidth: sidebarWidth),
            lanes: SidebarSlideTrailingChromeCapture.capture(in: reference, buttonCount: buttonCount),
            docked: docked ? SidebarSlidePaneLayout.measure(in: reference) : nil
        )
    }

    /// The terminal and browser views the portals draw over the panes.
    static func hostedViews(in window: NSWindow) -> [NSView] {
        guard let portal = TerminalWindowPortalRegistry.portalsByWindowId[ObjectIdentifier(window)],
              let container = portal.installedReferenceView?.superview else { return [] }
        let browsers = container.subviews.filter { $0 is WindowBrowserHostView }.flatMap(\.subviews)
        return portal.hostView.subviews + browsers
    }
}
