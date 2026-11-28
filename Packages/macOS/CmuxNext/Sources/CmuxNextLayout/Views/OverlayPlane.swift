public import AppKit

/// The layout's non-interactive overlays (focus ring, inactive dim, drop
/// highlight) live in one plane that covers the layout root exactly. Items
/// are placed in the root's coordinates, so the plane works in either home:
///
/// - inside the root (default, and whenever the window has no content child
///   windows), a top subview;
/// - inside a window-level overlay that sits above content child windows
///   (Chromium pages are child `NSWindow`s ordered above the whole parent
///   content), when the root's window adopts it (``OverlayPlaneHosting``).
///
/// The plane never takes hits; overlays that need the mouse are reported as
/// ``LayoutRootView/interactiveOverlayRects`` instead.
public final class OverlayPlane: NSView {
    /// The view whose bounds the plane mirrors (the layout root).
    public private(set) weak var home: NSView?

    init(home: NSView) {
        self.home = home
        super.init(frame: home.bounds)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override public var isFlipped: Bool { true }
    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Whether the plane lives in its home (not adopted by a window overlay).
    public var isHome: Bool { superview === home }

    /// The home's bounds in window coordinates (nil outside a window).
    public var homeRectInWindow: CGRect? {
        guard let home, home.window != nil else { return nil }
        return home.convert(home.bounds, to: nil)
    }

    /// Matches the plane's frame to the home. In the home that is its
    /// bounds; in a window overlay whose content view has the parent
    /// window's geometry, it is the home's rect in window coordinates.
    /// Returns whether the frame or visibility changed.
    @discardableResult
    public func syncFrame() -> Bool {
        guard let home, let superview else { return false }
        let target: CGRect
        let hidden: Bool
        if superview === home {
            target = home.bounds
            hidden = false
        } else if let rect = homeRectInWindow {
            target = superview.convert(rect, from: nil)
            hidden = home.isHiddenOrHasHiddenAncestor
        } else {
            target = .zero
            hidden = true
        }
        let changed = frame != target || isHidden != hidden
        if frame != target { frame = target }
        if isHidden != hidden { isHidden = hidden }
        syncClip()
        return changed
    }

    /// Adopted, the plane sits outside the layout's clipping ancestors, so
    /// it masks itself to the nearest rounded one (the window's curved main
    /// pane, cx-rkgu); at home that ancestor clips it already. Without this,
    /// a ring or dim at a rounded corner paints square while a Chromium
    /// page shows.
    private func syncClip() {
        guard let home, let superview, superview !== home, home.window != nil,
              let clip = Self.roundedClip(around: home) else {
            if layer?.mask != nil { layer?.mask = nil }
            return
        }
        let rect = convert(superview.convert(clip.rect, from: nil), from: superview)
        let radius = min(clip.radius, rect.width / 2, rect.height / 2)
        let mask = (layer?.mask as? CAShapeLayer) ?? CAShapeLayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = bounds
        mask.path = rect.isEmpty ? nil : CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if layer?.mask !== mask { layer?.mask = mask }
        CATransaction.commit()
    }

    /// The nearest view at or above `view` whose layer clips with a corner
    /// radius: its bounds in window coordinates and its radius.
    static func roundedClip(around view: NSView) -> (rect: CGRect, radius: CGFloat)? {
        var current: NSView? = view
        while let candidate = current {
            if let layer = candidate.layer, layer.masksToBounds, layer.cornerRadius > 0 {
                return (candidate.convert(candidate.bounds, to: nil), layer.cornerRadius)
            }
            current = candidate.superview
        }
        return nil
    }

    /// Whether the plane's frame matches its home (for `debug.layers`).
    public var isInSync: Bool {
        guard let superview else { return false }
        if superview === home { return frame == home?.bounds }
        guard let rect = homeRectInWindow else { return isHidden }
        return frame == superview.convert(rect, from: nil)
    }
}

/// Implemented by a window that keeps a layer above its content child
/// windows. The layout root offers its plane when it enters the window and
/// takes it back when it leaves.
@MainActor
public protocol OverlayPlaneHosting: AnyObject {
    /// Places `plane` (in its home or in the window overlay) and keeps it
    /// there until ``releasePlane(_:)``.
    func adoptPlane(_ plane: OverlayPlane)
    /// Stops managing `plane`. The caller puts it back in its home.
    func releasePlane(_ plane: OverlayPlane)
    /// The interactive overlay rects or divider mouse areas of a plane
    /// changed (`LayoutRootView.interactiveOverlayRects`, `dividerMouseAreas`).
    func interactiveOverlayRectsDidChange(_ plane: OverlayPlane)
    /// The plane's home finished a layout pass (its size or position may
    /// have changed); not called on animation frames.
    func planeDidLayout(_ plane: OverlayPlane)
    /// Pane padding or corner radius changed: content drawn outside the
    /// view tree (Chromium page windows) must re-read its clip shape even
    /// where no frame moved.
    func paneShapesDidChange(_ plane: OverlayPlane)
}
