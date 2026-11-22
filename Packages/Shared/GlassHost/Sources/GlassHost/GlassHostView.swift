public import AppKit

/// The layer of glass under a see-through web view. Put it right under the web view, at the web view's
/// frame (``place(under:)``), and hand it each message the page sends (``apply(_:zoom:)``): it makes,
/// moves, rounds, fades and removes one glass view per surface, at the surface's box. The web view
/// stays on top, so the page draws each surface's content over its glass and takes every click; this
/// view takes none.
///
/// Why under the web view and not a window of its own: a page's popover is the page's own element, so
/// its text, focus, keys and scrolling stay in the page. Only the material is native.
@MainActor
public final class GlassHostView: NSView {
    /// Makes one surface's glass. The default is the system's (``GlassMaterialView``).
    public var makeSurface: (GlassLevel) -> any GlassSurfaceView = { GlassMaterialView(level: $0) }
    /// The glass views by surface id, as last applied.
    public private(set) var surfaces: [String: any GlassSurfaceView] = [:]
    /// The last message applied.
    public private(set) var states: [GlassSurfaceState] = []
    /// The page's zoom (CSS pixel to point) at the last message.
    public private(set) var zoom: CGFloat = 1

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override var isFlipped: Bool { true }

    /// Puts this view right under `webView` in its superview, at its frame. Call it again after a
    /// layout that moves the web view (or keep the two frames equal yourself).
    public func place(under webView: NSView) {
        guard let parent = webView.superview else { return }
        if superview !== parent || parent.subviews.firstIndex(of: self).map({ $0 + 1 }) != parent.subviews.firstIndex(of: webView) {
            removeFromSuperview()
            parent.addSubview(self, positioned: .below, relativeTo: webView)
        }
        if frame != webView.frame { frame = webView.frame }
        if !states.isEmpty { layoutSurfaces() }
    }

    /// Draws the page's last message: `states` (``GlassSurfaceState/decode(_:)``) at `zoom`. Glass that
    /// is no longer listed goes. An empty list removes every surface.
    public func apply(_ states: [GlassSurfaceState], zoom: CGFloat = 1) {
        self.states = states
        self.zoom = max(0.25, zoom)
        var kept = Set<String>()
        for state in states {
            kept.insert(state.id)
            if surfaces[state.id] == nil {
                let view = makeSurface(state.level)
                view.translatesAutoresizingMaskIntoConstraints = true
                addSubview(view)
                surfaces[state.id] = view
            }
        }
        for (id, view) in surfaces where !kept.contains(id) {
            view.removeFromSuperview()
            surfaces[id] = nil
        }
        layoutSurfaces()
    }

    public override func layout() {
        super.layout()
        layoutSurfaces()
    }

    private func layoutSurfaces() {
        for state in states {
            guard let view = surfaces[state.id] else { continue }
            let frame = Self.frame(of: state.rect, zoom: zoom)
            if view.frame != frame { view.frame = frame }
            let radius = state.radius * zoom
            if view.cornerRadius != radius { view.cornerRadius = radius }
            if view.alphaValue != state.opacity { view.alphaValue = state.opacity }
        }
    }

    /// A surface's box (CSS pixels from the page's top-left) in this view, which is flipped and laid
    /// over the web view.
    public static func frame(of rect: CGRect, zoom: CGFloat) -> CGRect {
        let scale = max(0.25, zoom)
        return CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
    }
}
