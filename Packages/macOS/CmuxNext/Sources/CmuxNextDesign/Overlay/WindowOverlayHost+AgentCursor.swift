public import AppKit
public import CmuxNextDesignTokens

/// The view that carries a window's agent cursor layer. It takes the mouse
/// only on a name tag, which is a link to its agent's workspace (user,
/// 2026-10-20): a pointing hand, a highlight and a tooltip on hover, a press
/// on click. Each tag is a VoiceOver button; the carrier itself is no element.
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
    /// The clickable tags (`WindowOverlayHost.agentCursorTags`).
    weak var tags: (any AgentCursorTagSource)?
    /// The tag under the pointer.
    private(set) var hovered: AgentCursorTagTarget?
    /// The tag a mouse down landed on; its mouse up there presses it.
    private var pressing: String?
    private var tracking: NSTrackingArea?

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

    /// The carrier's own (y-up) rect of a y-down cursor-layer rect.
    func localRect(_ frame: CGRect) -> NSRect {
        NSRect(x: frame.minX, y: bounds.height - frame.maxY, width: frame.width, height: frame.height)
    }

    /// The tag at `point` in the carrier's own coordinates.
    func tag(at point: NSPoint) -> AgentCursorTagTarget? {
        guard let tags else { return nil }
        let down = CGPoint(x: point.x, y: bounds.height - point.y)
        return tags.agentCursorTags().last { $0.frame.contains(down) }
    }

    /// Only a tag takes the mouse; every other click goes to the page.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, tags != nil else { return nil }
        return tag(at: convert(point, from: superview)) == nil ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressing = tag(at: convert(event.locationInWindow, from: nil))?.id
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressing = nil }
        guard let id = pressing, tag(at: convert(event.locationInWindow, from: nil))?.id == id else { return }
        tags?.pressAgentCursorTag(id)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard tracking == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                                                         .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        hover(tag(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) { hover(nil) }

    override func cursorUpdate(with event: NSEvent) {
        if hovered != nil { NSCursor.pointingHand.set() } else { super.cursorUpdate(with: event) }
    }

    /// The pointer is on `tag`, or on no tag: a pointing hand, the tag's
    /// highlight (by its source) and its tooltip.
    func hover(_ tag: AgentCursorTagTarget?) {
        if tag != nil { NSCursor.pointingHand.set() }
        guard tag?.id != hovered?.id else { return }
        let left = hovered != nil
        hovered = tag
        tags?.hoverAgentCursorTag(tag?.id)
        if let tag {
            setThemedToolTipRegions([(rect: localRect(tag.frame), text: tag.help)])
            if let tracker = TooltipTracker.all(of: self).last { TooltipPresenter.shared.enter(tracker) }
        } else {
            setThemedToolTipRegions([])
            if left { NSCursor.arrow.set() }
        }
    }

    override func accessibilityChildren() -> [Any]? {
        (tags?.agentCursorTags() ?? []).map { tag in
            AgentCursorTagElement(tag, frame: localRect(tag.frame), parent: self) { [weak self] in
                self?.tags?.pressAgentCursorTag(tag.id)
            }
        }
    }

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
        carrier.tags = agentCursorTags
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

    /// The window's agent cursors came, went, showed or hid: the panel
    /// takes the mouse over their tags (`acceptsMouse`) while any shows.
    public func agentCursorTagsDidChange() {
        if agentCursorTags?.agentCursorTags().isEmpty != false { agentCursorCarrier?.hover(nil) }
        updateMouseRouting()
    }

    /// The tag under `point` in the panel's coordinates, while the cursor
    /// draws in the panel (else the window's own views route the mouse).
    func agentCursorTag(atPanelPoint point: NSPoint) -> AgentCursorTagTarget? {
        guard let carrier = agentCursorCarrier, carrier.window === panel else { return nil }
        return carrier.tag(at: carrier.convert(point, from: nil))
    }

    /// Whether any agent cursor tag shows in the panel now.
    var showsAgentCursorTags: Bool {
        guard let carrier = agentCursorCarrier, carrier.window === panel else { return false }
        return agentCursorTags?.agentCursorTags().isEmpty == false
    }

    /// The pointer is at `point` in the panel's coordinates: the tag under it
    /// (or none) is hovered.
    func hoverAgentCursorTag(at point: NSPoint) {
        guard let carrier = agentCursorCarrier, carrier.window === panel else { return }
        carrier.hover(agentCursorTag(atPanelPoint: point))
    }

    /// Where a click on the tag of cursor `id` lands: the window that draws
    /// the cursor (the overlay panel or the main window) and the tag's
    /// center in its coordinates; nil when the tag is not shown (debug input).
    public func agentCursorTagClickPoint(_ id: String) -> (window: NSWindow, point: NSPoint)? {
        guard let carrier = agentCursorCarrier, let window = carrier.window,
              let tag = agentCursorTags?.agentCursorTags().first(where: { $0.id == id }) else { return nil }
        let local = carrier.localRect(tag.frame)
        return (window, carrier.convert(NSPoint(x: local.midX, y: local.midY), to: nil))
    }

    func removeAgentCursor() {
        agentCursorCarrier?.removeFromSuperview()
    }
}
