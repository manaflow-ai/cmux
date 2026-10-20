public import AppKit

/// The view that carries a window's agent cursor layer. It takes no mouse
/// (`hitTest` is nil) and no accessibility focus.
///
/// Two subviews, bottom to top: a behind-window glass (`NSVisualEffectView`)
/// masked by `glassLayer`, where each cursor cuts its name tag and caption
/// shapes, and the view holding `cursorLayer`. The carrier sits in the
/// overlay panel, a window above the Chromium page windows, so the glass
/// blurs the page under each tag (user, 2026-10-20: "get a real blur").
final class AgentCursorCarrierView: NSView {
    let cursorLayer = CALayer()
    /// The glass's mask: y-down, the carrier's bounds; empty until a cursor shows a tag.
    let glassLayer = CALayer()
    let glassView = NSVisualEffectView()
    private let cursorView = PassThroughLayerView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glassView.blendingMode = .behindWindow
        glassView.material = .hudWindow
        glassView.state = .active
        // A light glass under the tag's dark label, on light and dark pages alike.
        glassView.appearance = NSAppearance(named: .aqua)
        glassView.wantsLayer = true
        glassView.autoresizingMask = [.width, .height]
        glassLayer.name = "agentCursor.glass"
        glassLayer.isGeometryFlipped = true
        cursorView.wantsLayer = true
        cursorView.autoresizingMask = [.width, .height]
        cursorLayer.name = "agentCursor"
        // Content-view coordinates, y-down (the agent cursor's geometry).
        cursorLayer.isGeometryFlipped = true
        cursorView.layer?.addSublayer(cursorLayer)
        addSubview(glassView)
        addSubview(cursorView)
        glassView.layer?.mask = glassLayer
        setAccessibilityElement(false)
        syncLayerFrame()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncLayerFrame()
    }

    func syncLayerFrame() {
        if glassView.frame != bounds { glassView.frame = bounds }
        if cursorView.frame != bounds { cursorView.frame = bounds }
        let local = CGRect(origin: .zero, size: bounds.size)
        guard cursorLayer.frame != local || glassLayer.frame != local else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.frame = local
        glassLayer.frame = local
        // AppKit may replace the glass view's layer; keep the mask on the current one.
        if glassView.layer?.mask !== glassLayer { glassView.layer?.mask = glassLayer }
        CATransaction.commit()
    }
}

/// A layer-backed view that never takes the mouse.
private final class PassThroughLayerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension WindowOverlayHost {
    /// The window's agent cursor layer, made on first use: y-down, in the
    /// coordinates of the window's content view, above Chromium pages, the
    /// sidebar and `.window` overlays, below modal overlays, never hit by the
    /// mouse. It is in the overlay panel (between the window and modal
    /// containers) while the panel is attached, else on top of the window's
    /// content view; callers hold the layer, never its superlayer.
    public var agentCursorLayer: CALayer { agentCursorCarrierView.cursorLayer }

    /// The mask of the cursor's behind-window glass, in `agentCursorLayer`'s
    /// coordinates: each cursor adds its tag and caption shapes here, and the
    /// page under them is blurred.
    public var agentCursorGlassLayer: CALayer { agentCursorCarrierView.glassLayer }

    private var agentCursorCarrierView: AgentCursorCarrierView {
        if let agentCursorCarrier { return agentCursorCarrier }
        let carrier = AgentCursorCarrierView(frame: .zero)
        agentCursorCarrier = carrier
        placeAgentCursor()
        return carrier
    }

    /// A subview was added to the window's content view (`WindowRootView`):
    /// while the panel is detached, the cursor goes back on top.
    public func contentViewDidAddSubview(_ subview: NSView) {
        guard let carrier = agentCursorCarrier, subview !== carrier, !isPanelAttached,
              let content = window?.contentView, carrier.superview === content, content.subviews.last !== carrier else { return }
        placeAgentCursor()
    }

    /// The content view's layout pass (`WindowRootView.layout`): a reorder
    /// that added nothing (`sortSubviews`, a `subviews =` assignment) may
    /// have covered the cursor while the panel is detached. Puts it back on
    /// top; true when it had to (logged in debug builds).
    @discardableResult
    public func repairAgentCursorOrder() -> Bool {
        guard let carrier = agentCursorCarrier, !isPanelAttached, !isAppHost,
              let content = window?.contentView, carrier.superview === content, content.subviews.last !== carrier else { return false }
        #if DEBUG
        NSLog("cmux: the agent cursor was covered by a reorder of the window's content view; raised again")
        #endif
        placeAgentCursor()
        return true
    }

    /// Puts the cursor carrier where it draws now and sizes it to the
    /// content view. Runs on every attach, detach and window geometry change.
    func placeAgentCursor() {
        guard let carrier = agentCursorCarrier else { return }
        if isAppHost || isPanelAttached {
            guard let root = panel.contentView else { return }
            let subviews = root.subviews
            let modal = subviews.firstIndex { $0 === panel.modalContainer }
            let current = subviews.firstIndex { $0 === carrier }
            if carrier.superview !== root || current.map({ $0 + 1 }) != modal {
                root.addSubview(carrier, positioned: .below, relativeTo: panel.modalContainer)
            }
            carrier.autoresizingMask = []
            carrier.frame = contentFrameInPanel(root: root)
            // In the panel, a window above the page windows: blur what is behind the panel.
            carrier.glassView.blendingMode = .behindWindow
        } else if let content = window?.contentView {
            if carrier.superview !== content || content.subviews.last !== carrier {
                content.addSubview(carrier, positioned: .above, relativeTo: nil)
            }
            carrier.autoresizingMask = [.width, .height]
            carrier.frame = content.bounds
            // On the window's own content (no page windows): blur the views under it, never the desktop.
            carrier.glassView.blendingMode = .withinWindow
        } else {
            carrier.removeFromSuperview()
        }
        carrier.syncLayerFrame()
    }

    /// The window's content view in panel-root coordinates. The panel has the
    /// window's frame, so window coordinates differ only by the frames' offset.
    private func contentFrameInPanel(root: NSView) -> NSRect {
        guard let window, let content = window.contentView else { return root.bounds }
        let inWindow = content.convert(content.bounds, to: nil)
        let inPanel = inWindow.offsetBy(dx: window.frame.minX - panel.frame.minX, dy: window.frame.minY - panel.frame.minY)
        return root.convert(inPanel, from: nil)
    }

    func removeAgentCursor() {
        agentCursorCarrier?.removeFromSuperview()
    }
}
