public import AppKit

public extension WindowOverlayHost {
    /// Shows `content` above the window's content and every page of the window. `content` keeps its
    /// frame size (its fitting size when it has none); the kind and anchor
    /// decide where it goes. A content that later changes size by Auto Layout is read in its holder's
    /// `layout()`; one that sets its own frame tells its handle (``OverlayHandle/contentDidResize()``).
    func present(_ content: NSView, options: OverlayOptions) -> OverlayHandle {
        let handle = OverlayHandle(id: nextID, content: content, options: options, host: self)
        nextID += 1
        if content.frame.size == .zero { content.setFrameSize(content.fittingSize) }
        let container = topLayer.container(for: options.effectiveLayer)
        var scrim: OverlayScrimView?
        if options.dimsContent, !isAppHost {
            let view = OverlayScrimView(frame: container.bounds)
            view.identifier = NSUserInterfaceItemIdentifier("overlay-scrim-\(handle.id)")
            container.addSubview(view)
            scrim = view
        }
        content.removeFromSuperview()
        // Presented again while its close was fading out.
        content.alphaValue = 1
        if case .pane(let clip) = options.effectiveLayer, !isAppHost {
            let clipView = OverlayClipView(frame: clip)
            clipView.onLayout = { [weak self] in self?.containerDidLayout() }
            clipView.addSubview(content)
            container.addSubview(clipView)
            handle.clipView = clipView
        } else {
            container.addSubview(content)
        }
        handles.append(handle)
        cachedRegions = nil
        syncPanel()
        layout(handle)
        if options.kind == .dialog { fadeIn([scrim, content].compactMap(\.self)) }
        if options.isModal { beginModal(handle) }
        updateMouseRouting()
        updateEscapeIntercept()
        onBlockingChange?()
        changes?.signal()
        return handle
    }

    /// A dialog and its scrim fade in (POLISH: no flash): shown in one frame, the whole window
    /// darkened at once. The fade-in token, which Reduce Motion keeps.
    private func fadeIn(_ views: [NSView]) {
        for view in views {
            view.wantsLayer = true
            guard let layer = view.layer else { continue }
            Motion.overlays.set(layer, "opacity", to: Float(1), fade: .fadeIn, from: Float(0))
        }
    }

    /// 0 for `.pane`, 1 for `.window`, 2 for `.modal` (bottom to top).
    func layerIndex(of handle: OverlayHandle) -> Int {
        switch handle.options.effectiveLayer {
        case .pane: 0
        case .window: 1
        case .modal: 2
        }
    }

    /// The overlay's frame in window coordinates.
    func frameInWindow(_ handle: OverlayHandle) -> NSRect {
        guard let clip = handle.clipView else { return handle.content.frame }
        return handle.content.frame.offsetBy(dx: clip.frame.minX, dy: clip.frame.minY)
    }

    /// What of the overlay shows (window coordinates): a `.pane` overlay
    /// inside its clip and outside every occluder.
    func visibleRegion(of handle: OverlayHandle) -> [NSRect] {
        let frame = frameInWindow(handle)
        guard case .pane(let clip) = handle.options.effectiveLayer else { return [frame] }
        return Self.subtract(occluderRects, from: frame.intersection(clip))
    }

    /// `rect` minus every rect of `holes`, as disjoint rects.
    nonisolated static func subtract(_ holes: [NSRect], from rect: NSRect) -> [NSRect] {
        var pieces = rect.isEmpty ? [] : [rect]
        for hole in holes {
            pieces = pieces.flatMap { piece -> [NSRect] in
                let cut = piece.intersection(hole)
                guard !cut.isEmpty else { return [piece] }
                return [
                    NSRect(x: piece.minX, y: piece.minY, width: piece.width, height: cut.minY - piece.minY),
                    NSRect(x: piece.minX, y: cut.maxY, width: piece.width, height: piece.maxY - cut.maxY),
                    NSRect(x: piece.minX, y: cut.minY, width: cut.minX - piece.minX, height: cut.height),
                    NSRect(x: cut.maxX, y: cut.minY, width: piece.maxX - cut.maxX, height: cut.height),
                ].filter { $0.width > 0 && $0.height > 0 }
            }
        }
        return pieces
    }

    /// Whether the overlays take the mouse at `point` (window coordinates; the top layer's hit test in the
    /// window, the panel's routing in the panel):
    /// over a modal or dimming overlay's window, a modal region, or an
    /// overlay that does not pass clicks through.
    func acceptsMouse(at point: NSPoint) -> Bool {
        interactiveRegions().contains { $0.contains(point) } || agentCursorTag(atPanelPoint: point) != nil
    }

    /// Input-blocking rects, window coordinates (cached until something changes). The cache is
    /// also checked against the frames it was built from, so a content that grows or shrinks on its
    /// own (a SwiftUI popover) is hit-tested at its new size.
    func interactiveRegions() -> [NSRect] {
        if let cachedRegions, regionsFramesAreCurrent() { return cachedRegions }
        let regions = buildInteractiveRegions()
        cachedRegions = regions
        cachedRegionsFrames = [topLayer.overlayContainer.bounds] + handles.map { frameInWindow($0) }
        return regions
    }

    /// The container bounds and every overlay frame still equal those the cached regions were built from.
    private func regionsFramesAreCurrent() -> Bool {
        guard cachedRegionsFrames.count == handles.count + 1,
              cachedRegionsFrames[0] == topLayer.overlayContainer.bounds else { return false }
        for (index, handle) in handles.enumerated() where cachedRegionsFrames[index + 1] != frameInWindow(handle) {
            return false
        }
        return true
    }

    /// The panel laid out its overlays (a window resize, a content Auto Layout resized): the panel takes or
    /// lets go of the mouse under a pointer that did not move, read from the frames now.
    func containerDidLayout() {
        guard cachedRegions != nil, !regionsFramesAreCurrent() else { return }
        updateMouseRouting()
    }

    private func buildInteractiveRegions() -> [NSRect] {
        let bounds = topLayer.overlayContainer.bounds
        return handles.flatMap { handle -> [NSRect] in
            let options = handle.options
            if options.dimsContent || (options.isModal && options.modalRegion == nil) { return [bounds] }
            var rects: [NSRect] = []
            if let region = options.modalRegion { rects.append(region) }
            if !options.passesThroughClicks { rects += visibleRegion(of: handle) }
            return rects
        }
    }
}

extension WindowOverlayHost {
    func remove(_ handle: OverlayHandle) {
        handles.removeAll { $0 === handle }
        cachedRegions = nil
        let scrims = [topLayer.paneContainer, topLayer.windowContainer, topLayer.modalContainer].flatMap { container in
            container.subviews.filter { $0.identifier?.rawValue == "overlay-scrim-\(handle.id)" }
        }
        let shown = (handle.clipView.map { [$0] } ?? [handle.content]) + scrims
        handle.clipView = nil
        if handle.options.kind == .dialog, !isTearingDown {
            // The fading dialog keeps no keyboard focus: a Return in the fade would press it again.
            if let overlayWindow, let responder = overlayWindow.firstResponder as? NSView, responder.isDescendant(of: handle.content) {
                overlayWindow.makeFirstResponder(nil)
            }
            fadeOut(shown, content: handle.content)
        } else {
            handle.content.removeFromSuperview()
            shown.forEach { $0.removeFromSuperview() }
        }
        if handle.options.isModal { endModal() }
        updateMouseRouting()
        updateEscapeIntercept()
        syncPanel()
        onBlockingChange?()
        changes?.signal()
    }

    /// A dialog and its scrim fade out (POLISH: no flash) where they were. The dialog is already
    /// gone: it takes no input, and the window under it is usable at once. A view leaves only if it
    /// is still where the fade found it: a dialog presented again meanwhile, here or in another
    /// window (its tab moved there), stays where it went.
    private func fadeOut(_ views: [NSView], content: NSView) {
        fadingOut += 1
        let parents = (views + [content]).map { ($0, $0.superview) }
        Motion.overlays.animate(.fadeOut, in: views.first, {
            views.forEach { $0.animator().alphaValue = 0 }
        }, completion: { [weak self] in
            guard let self else { return }
            fadingOut -= 1
            let presented = handles.contains { $0.content === content }
            for (view, parent) in parents where parent != nil && view.superview === parent && !(presented && view === content) {
                view.removeFromSuperview()
                view.alphaValue = 1
            }
            syncPanel()
        })
    }

    /// Places `handle` in top layer coordinates, which are the window's own.
    func layout(_ handle: OverlayHandle) {
        cachedRegions = nil
        if isAppHost { return layoutAppPanel() }
        let bounds = topLayer.overlayContainer.bounds.isEmpty ? (window?.contentView?.bounds ?? .zero) : topLayer.overlayContainer.bounds
        guard case .pane(let clip) = handle.options.effectiveLayer, let clipView = handle.clipView else {
            handle.content.setFrameOrigin(Self.origin(for: handle.content.frame.size, options: handle.options, in: bounds))
            return updateMouseRouting()
        }
        // Placed inside its pane; the clip view masks the occluders out.
        clipView.frame = clip
        let origin = Self.origin(for: handle.content.frame.size, options: handle.options, in: clip)
        handle.content.setFrameOrigin(NSPoint(x: origin.x - clip.minX, y: origin.y - clip.minY))
        let visible = Self.subtract(occluderRects, from: clip).map { $0.offsetBy(dx: -clip.minX, dy: -clip.minY) }
        clipView.setVisibleRects(visible, whole: occluderRects.allSatisfy { !$0.intersects(clip) })
        updateMouseRouting()
    }

    /// Where an overlay of `size` goes, clamped inside `bounds` (8 pt inset).
    nonisolated static func origin(for size: NSSize, options: OverlayOptions, in bounds: NSRect) -> NSPoint {
        if options.kind == .attached, let anchor = options.anchor { return anchor.origin }
        let inset: CGFloat = 8
        var origin: NSPoint
        switch (options.kind, options.anchor) {
        case (.dialog, let anchor?):
            origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.midY - size.height / 2)
        case (.dialog, nil), (.tooltip, nil), (.popover, nil), (.menu, nil), (.dragGhost, nil), (.attached, nil):
            origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        case (.toast, let anchor):
            let area = anchor ?? bounds
            origin = NSPoint(x: area.midX - size.width / 2, y: area.minY + 24)
        case (.dragGhost, let anchor?), (.attached, let anchor?):
            origin = anchor.origin
        case (.tooltip, let anchor?), (.popover, let anchor?), (.menu, let anchor?):
            // Below the anchor; above it when there is no room below.
            let below = anchor.minY - 4 - size.height
            origin = NSPoint(x: anchor.minX, y: below >= bounds.minY + inset ? below : anchor.maxY + 4)
        }
        origin.x = min(max(origin.x, bounds.minX + inset), max(bounds.minX + inset, bounds.maxX - size.width - inset))
        origin.y = min(max(origin.y, bounds.minY + inset), max(bounds.minY + inset, bounds.maxY - size.height - inset))
        return origin
    }

    func layoutAppPanel() {
        let size = handles.reduce(NSSize.zero) { NSSize(width: max($0.width, $1.content.frame.width),
                                                        height: max($0.height, $1.content.frame.height)) }
        let screen = Self.appHostScreenFrame()
        panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        for handle in handles { handle.content.setFrameOrigin(.zero) }
    }
}
