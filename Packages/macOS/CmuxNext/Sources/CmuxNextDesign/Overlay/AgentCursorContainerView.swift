public import AppKit

/// Holds a window's agent cursor layer (`WindowOverlayHost.agentCursorLayer`).
/// The view is the size of the content view and never takes the mouse. The
/// host moves it between the overlay panel (above page windows, below modal
/// overlays) and the window's content view (top subview) as the panel
/// attaches and detaches.
final class AgentCursorContainerView: NSView {
    let cursorLayer = AgentCursorRootLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        layer?.addSublayer(cursorLayer)
        syncLayerFrame()
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncLayerFrame()
    }

    override func layout() {
        super.layout()
        syncLayerFrame()
    }

    func syncLayerFrame() {
        guard cursorLayer.frame != bounds else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.frame = bounds
        CATransaction.commit()
    }
}

/// The agent cursor layer: y-down (content-view coordinates) and never a hit target.
nonisolated final class AgentCursorRootLayer: CALayer {
    override init() {
        super.init()
        isGeometryFlipped = true
        masksToBounds = false
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: CGPoint) -> CALayer? { nil }
    override func contains(_ point: CGPoint) -> Bool { false }
    override func action(forKey event: String) -> (any CAAction)? { nil }
}

extension WindowOverlayHost {
    /// The window's agent cursor layer, made on first use. Its bounds are
    /// the content view's bounds, y-down, so a cursor at a content-view point
    /// needs no conversion. It is above the layout, the sidebar, every page
    /// window and window overlays, below modal overlays, and never takes the
    /// mouse. Only the agent cursor host (`AgentCursorLayerHost`) adds
    /// sublayers. The layer changes superlayer when the overlay panel
    /// attaches or detaches, so callers must never keep a reference to its
    /// superlayer or convert through it; content-view points need no conversion.
    public var agentCursorLayer: CALayer { agentCursorView.cursorLayer }

    var agentCursorView: AgentCursorContainerView {
        if let view = agentCursorContainer { return view }
        let view = AgentCursorContainerView(frame: .zero)
        agentCursorContainer = view
        placeAgentCursor()
        return view
    }

    /// Puts the cursor container on the attached panel (below the modal
    /// container) or on top of the content view, at the content view's rect.
    func placeAgentCursor() {
        guard let view = agentCursorContainer, !isAppHost, let window, let content = window.contentView else { return }
        if panel.parent === window, let root = panel.contentView {
            if view.superview !== root || root.subviews.firstIndex(of: view) != root.subviews.firstIndex(of: panel.modalContainer).map({ $0 - 1 }) {
                root.addSubview(view, positioned: .below, relativeTo: panel.modalContainer)
            }
            let rect = content.convert(content.bounds, to: nil)
            if view.frame != rect { view.frame = rect }
        } else {
            if view.superview !== content || content.subviews.last !== view {
                content.addSubview(view, positioned: .above, relativeTo: nil)
            }
            if view.frame != content.bounds { view.frame = content.bounds }
        }
        view.syncLayerFrame()
    }

    /// The window's content view added `subview`. While the panel is
    /// detached the cursor view stays the content view's top subview, so a
    /// later subview (the titlebar badge, added `.above`) never covers it.
    /// The content view's `didAddSubview` calls this.
    public func contentViewDidAddSubview(_ subview: NSView) {
        guard let view = agentCursorContainer, subview !== view, let content = view.superview,
              content === window?.contentView, content.subviews.last !== view else { return }
        content.addSubview(view, positioned: .above, relativeTo: nil)
    }
}
