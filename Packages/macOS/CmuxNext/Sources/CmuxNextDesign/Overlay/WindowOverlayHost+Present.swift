public import AppKit

public extension WindowOverlayHost {
    /// Shows `content` above every page of the window. `content` keeps its
    /// frame size (its fitting size when it has none); the kind and anchor
    /// decide where it goes.
    func present(_ content: NSView, options: OverlayOptions) -> OverlayHandle {
        let handle = OverlayHandle(id: nextID, content: content, options: options, host: self)
        nextID += 1
        if content.frame.size == .zero { content.setFrameSize(content.fittingSize) }
        let container = panel.container(for: options.effectiveLayer)
        if options.dimsContent, !isAppHost {
            let scrim = OverlayScrimView(frame: container.bounds)
            scrim.identifier = NSUserInterfaceItemIdentifier("overlay-scrim-\(handle.id)")
            container.addSubview(scrim)
        }
        content.removeFromSuperview()
        if case .pane(let clip) = options.effectiveLayer, !isAppHost {
            let clipView = OverlayClipView(frame: clip)
            clipView.addSubview(content)
            container.addSubview(clipView)
            handle.clipView = clipView
        } else {
            container.addSubview(content)
        }
        handles.append(handle)
        cachedRegions = nil
        // A content that grows or shrinks on its own (a SwiftUI popover) changes the regions.
        handle.contentPostedFrameChanges = content.postsFrameChangedNotifications
        content.postsFrameChangedNotifications = true
        handle.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: content, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cachedRegions = nil
                self?.updateMouseRouting()
            }
        }
        syncPanel()
        layout(handle)
        if options.isModal { beginModal(handle) }
        updateMouseRouting()
        updateEscapeMonitor()
        onBlockingChange?()
        return handle
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

    /// Whether the panel takes the mouse at `point` (window coordinates):
    /// over a modal or dimming overlay's window, a modal region, or an
    /// overlay that does not pass clicks through.
    func acceptsMouse(at point: NSPoint) -> Bool {
        interactiveRegions().contains { $0.contains(point) }
    }

    /// Input-blocking rects, window coordinates (cached until something changes).
    func interactiveRegions() -> [NSRect] {
        if let cachedRegions { return cachedRegions }
        let regions = buildInteractiveRegions()
        cachedRegions = regions
        return regions
    }

    private func buildInteractiveRegions() -> [NSRect] {
        let bounds = panel.overlayContainer.bounds
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
        if let observer = handle.frameObserver { NotificationCenter.default.removeObserver(observer) }
        handle.frameObserver = nil
        handle.content.postsFrameChangedNotifications = handle.contentPostedFrameChanges
        handle.content.removeFromSuperview()
        handle.clipView?.removeFromSuperview()
        handle.clipView = nil
        for container in [panel.paneContainer, panel.windowContainer, panel.modalContainer] {
            container.subviews
                .filter { $0.identifier?.rawValue == "overlay-scrim-\(handle.id)" }
                .forEach { $0.removeFromSuperview() }
        }
        if handle.options.isModal { endModal() }
        updateMouseRouting()
        updateEscapeMonitor()
        syncPanel()
        onBlockingChange?()
    }

    /// Places `handle` in panel coordinates, which are the window's own.
    func layout(_ handle: OverlayHandle) {
        cachedRegions = nil
        if isAppHost { return layoutAppPanel() }
        let bounds = panel.overlayContainer.bounds.isEmpty ? (window?.contentView?.bounds ?? .zero) : panel.overlayContainer.bounds
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
        let inset: CGFloat = 8
        var origin: NSPoint
        switch (options.kind, options.anchor) {
        case (.dialog, let anchor?):
            origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.midY - size.height / 2)
        case (.dialog, nil), (.tooltip, nil), (.popover, nil), (.menu, nil), (.dragGhost, nil):
            origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        case (.toast, let anchor):
            let area = anchor ?? bounds
            origin = NSPoint(x: area.midX - size.width / 2, y: area.minY + 24)
        case (.dragGhost, let anchor?):
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
