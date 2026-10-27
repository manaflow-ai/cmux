import AppKit

extension WindowOverlayHost {
    // MARK: Top layer placement

    /// The top layer fills `panel`'s content (window coordinates: the panel has the window's frame).
    func mountTopLayer(in panel: OverlayHostPanel) {
        guard let root = panel.contentView, topLayer.superview !== root else { return }
        topLayer.frame = root.bounds
        root.addSubview(topLayer)
    }

    /// The top layer becomes the last subview of the window's content view, or leaves it (nil).
    func mountTopLayer(inWindowContent content: NSView?) {
        guard let content else {
            if let window, topLayer.window === window { topLayer.removeFromSuperview() }
            return
        }
        if topLayer.frame != content.bounds { topLayer.frame = content.bounds }
        if topLayer.superview !== content || content.subviews.last !== topLayer {
            content.addSubview(topLayer, positioned: .above, relativeTo: nil)
        }
    }

    /// A modal holds the keyboard where it draws now: a control of the top layer is that window's first
    /// responder and the keyboard did not move on (``focusMoved``).
    var modalHoldsKeyboard: Bool {
        guard keyObserver != nil, !focusMoved, let responder = overlayWindow?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: topLayer)
    }

    /// The top layer moved between the panel and the window: the mouse routing follows its new home, and a
    /// modal that held the keyboard (lost when its view left a window) takes it again in the new one. A
    /// keyboard the person moved elsewhere (a terminal beside a tab dialog) stays there.
    func topLayerDidChangeWindow(restoringKeyboard: Bool) {
        mouseRouting = nil
        cachedRegions = nil
        let top = handles.last { $0.options.isModal }
        madePanel?.acceptsKey = top != nil && usesPanel
        if let top, overlayWindow != nil, restoringKeyboard { giveKeyboard(to: top) }
        updateMouseRouting()
    }

    /// While a whole-window modal or dimming overlay shows in the window's top layer, the traffic lights
    /// take no click: AppKit's titlebar container draws above the content view, so the layer cannot cover
    /// them as the panel (a window above the whole window) did. They come back as they were when it goes.
    func syncWindowButtons() {
        guard let window else { return }
        let blocks = isTopLayerInWindow && blocksWholeWindow && !isTearingDown
        guard blocks != (blockedWindowButtons != nil) else { return }
        if blocks {
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
            let enabled = buttons.filter(\.isEnabled)
            enabled.forEach { $0.isEnabled = false }
            blockedWindowButtons = enabled
        } else {
            blockedWindowButtons?.forEach { $0.isEnabled = true }
            blockedWindowButtons = nil
        }
    }

    /// The window resized the top layer while it is in the window: the overlays follow, as the panel's do
    /// on the window's resize notification.
    func topLayerDidResize() {
        guard isTopLayerInWindow else { return }
        handles.forEach(layout)
        updateMouseRouting()
        placeAgentCursor()
    }
}
