import AppKit

/// Holds presented overlays; flipped so overlay frames read top-down in tests and logs.
final class OverlayContainerView: NSView {
    nonisolated override var isFlipped: Bool { false }

    /// A presented view's click regions in this view's coordinates (a dialog's card), nil when the
    /// whole view takes clicks. Set by the host.
    var clickRegions: (NSView) -> [NSRect]? = { _ in nil }

    /// A view takes only the clicks in its click region; the rest go to the views under it, so a
    /// dialog's transparent area never covers an older dialog's card (review 32 of #37296).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        for view in subviews.reversed() where !view.isHidden {
            if let regions = clickRegions(view), !regions.contains(where: { $0.contains(local) }) { continue }
            if let hit = view.hitTest(local) { return hit }
        }
        return frame.contains(point) ? self : nil
    }
}

/// Clips a `.pane` overlay to its pane minus the occluders (a mask with holes).
final class OverlayClipView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The parts of the clip that show (this view's coordinates); `whole`
    /// when no occluder touches the clip (no mask).
    func setVisibleRects(_ rects: [NSRect], whole: Bool) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard !whole else {
            layer.mask = nil
            return
        }
        let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        let path = CGMutablePath()
        for rect in rects { path.addRect(rect) }
        mask.frame = bounds
        mask.fillRule = .nonZero
        mask.path = path
        layer.mask = mask
    }
}

/// A scrim over the whole window under a dimming overlay, in the theme's ``Scrim`` strength.
final class OverlayScrimView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        updateLayer()
    }

    nonisolated override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let alpha = performWithTheme { (ThemeContext.active ?? ThemeScope.app.tokens).scrimAlpha }
        layer?.backgroundColor = NSColor.black.withAlphaComponent(alpha).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // The scrim takes clicks so nothing below reacts while a modal shows.
    override func mouseDown(with event: NSEvent) {}
}

/// The root of a window's overlays (`OverlayHostPanel.root`).
///
/// In the panel it is the panel's content view and takes the mouse as any view does (the panel itself ignores the
/// mouse outside interactive overlays). With in-tree pages it is a plain view on top of the main window's content
/// view (``inWindow``), and AppKit's normal hit test decides: it returns a hit only inside an interactive overlay
/// region (``acceptsMouse``) or on an agent cursor tag, and nil everywhere else, so the window's own views under it
/// get the mouse there. A press, release or scroll that reaches it ends here: nothing under an overlay gets it.
final class OverlayRootView: NSView {
    /// On top of the main window's content view (in-tree pages), not in the panel.
    var inWindow = false
    /// Whether an overlay takes the mouse at a point in this view's coordinates (the window's own while ``inWindow``).
    var acceptsMouse: (NSPoint) -> Bool = { _ in false }

    nonisolated override var isFlipped: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard inWindow else { return super.hitTest(point) }
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        let takes = acceptsMouse(local)
        for view in subviews.reversed() where !view.isHidden {
            if view is OverlayContainerView {
                // An empty container answers for itself (its whole frame), which in the panel was the panel's
                // own swallow: here only an overlay inside it counts, so a toast in the window container is not
                // hidden by the empty modal container above it.
                guard takes, let hit = view.hitTest(local), hit !== view else { continue }
                return hit
            }
            // The planes draw only; any other view (the agent cursor carrier) answers for itself.
            if view.identifier == Self.planeContainerID { continue }
            if let hit = view.hitTest(local) { return hit }
        }
        // Where an overlay takes the mouse but none of its views did (a card's margin), the root swallows it, as the
        // panel did: nothing under the overlay sees it.
        return takes ? self : nil
    }

    static let planeContainerID = NSUserInterfaceItemIdentifier("overlay-plane-container")

    // A press, release or scroll on an overlay that its own views did not take ends at the root: on the panel the
    // panel swallowed it, so nothing under the overlay may see it in the window either.
    override func mouseDown(with event: NSEvent) { if !inWindow { super.mouseDown(with: event) } }
    override func rightMouseDown(with event: NSEvent) { if !inWindow { super.rightMouseDown(with: event) } }
    override func otherMouseDown(with event: NSEvent) { if !inWindow { super.otherMouseDown(with: event) } }
    override func mouseUp(with event: NSEvent) { if !inWindow { super.mouseUp(with: event) } }
    override func rightMouseUp(with event: NSEvent) { if !inWindow { super.rightMouseUp(with: event) } }
    override func otherMouseUp(with event: NSEvent) { if !inWindow { super.otherMouseUp(with: event) } }
    override func scrollWheel(with event: NSEvent) { if !inWindow { super.scrollWheel(with: event) } }
}
