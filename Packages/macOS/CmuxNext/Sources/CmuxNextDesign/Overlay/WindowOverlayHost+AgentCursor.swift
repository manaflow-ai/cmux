public import AppKit

/// The view that carries a window's agent cursor layer. It takes no mouse
/// (`hitTest` is nil) and no accessibility focus; the layer is a sublayer of
/// its backing layer, sized to its bounds.
final class AgentCursorCarrierView: NSView {
    let cursorLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        cursorLayer.name = "agentCursor"
        // Content-view coordinates, y-down (the agent cursor's geometry).
        cursorLayer.isGeometryFlipped = true
        layer?.addSublayer(cursorLayer)
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
        guard cursorLayer.frame != bounds else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.frame = bounds
        CATransaction.commit()
    }
}

extension WindowOverlayHost {
    /// The window's agent cursor layer, made on first use: y-down, in the
    /// coordinates of the window's content view, above Chromium pages, the
    /// sidebar and `.window` overlays, below modal overlays, never hit by the
    /// mouse. It is in the overlay panel (between the window and modal
    /// containers) while the panel is attached, else on top of the window's
    /// content view; callers hold the layer, never its superlayer.
    public var agentCursorLayer: CALayer {
        if let agentCursorCarrier { return agentCursorCarrier.cursorLayer }
        let carrier = AgentCursorCarrierView(frame: .zero)
        agentCursorCarrier = carrier
        placeAgentCursor()
        return carrier.cursorLayer
    }

    /// A subview was added to the window's content view (`WindowRootView`):
    /// while the panel is detached, the cursor goes back on top.
    public func contentViewDidAddSubview(_ subview: NSView) {
        guard let carrier = agentCursorCarrier, subview !== carrier, !isPanelAttached,
              let content = window?.contentView, carrier.superview === content, content.subviews.last !== carrier else { return }
        placeAgentCursor()
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
        } else if let content = window?.contentView {
            if carrier.superview !== content || content.subviews.last !== carrier {
                content.addSubview(carrier, positioned: .above, relativeTo: nil)
            }
            carrier.autoresizingMask = [.width, .height]
            carrier.frame = content.bounds
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
