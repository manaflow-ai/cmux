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
    public func syncFrame() {
        guard let home, let superview else { return }
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
        if frame != target { frame = target }
        if isHidden != hidden { isHidden = hidden }
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
    /// The interactive overlay rects of a plane changed (window coordinates).
    func interactiveOverlayRectsDidChange(_ plane: OverlayPlane)
    /// The plane's home finished a layout pass (its size or position may
    /// have changed); not called on animation frames.
    func planeDidLayout(_ plane: OverlayPlane)
    /// Pane padding or corner radius changed: content drawn outside the
    /// view tree (Chromium page windows) must re-read its clip shape even
    /// where no frame moved.
    func paneShapesDidChange(_ plane: OverlayPlane)
}
