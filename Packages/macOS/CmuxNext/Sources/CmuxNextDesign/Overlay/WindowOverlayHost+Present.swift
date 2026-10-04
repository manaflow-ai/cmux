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

    // MARK: Mouse

    /// The panel takes the mouse only where an interactive overlay is. The
    /// window server picks a window before any app code sees a click, so the
    /// panel switches on mouse moves (and on every present, layout and
    /// dismiss) for the point under the pointer.
    func updateMouseRouting() {
        if isAppHost {
            panel.ignoresMouseEvents = handles.isEmpty
            return
        }
        let regions = interactiveRegions()
        guard !regions.isEmpty else {
            panel.ignoresMouseEvents = true
            removeMouseMonitor()
            return
        }
        routeMouse(at: NSEvent.mouseLocation)
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                                                   .otherMouseDragged, .mouseEntered, .mouseExited,
                                                                   .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                self.clickDidLand(in: event.window, at: event.window === self.panel ? event.locationInWindow : .zero)
            } else {
                self.routeMouse(at: NSEvent.mouseLocation)
            }
            return event
        }
    }

    func routeMouse(at screenPoint: NSPoint) {
        let point = panel.frame.isEmpty ? screenPoint : panel.convertPoint(fromScreen: screenPoint)
        let accepts = acceptsMouse(at: point)
        if panel.ignoresMouseEvents == accepts { panel.ignoresMouseEvents = !accepts }
    }

    /// A tab dialog takes the keyboard when a click lands on it; a click
    /// anywhere else leaves the keyboard where that click puts it.
    func wantsKey(forClickIn clicked: NSWindow?, at point: NSPoint) -> Bool {
        guard clicked === panel else { return false }
        let bounds = panel.overlayContainer.bounds
        return handles.contains { $0.options.isModal && ($0.options.modalRegion ?? bounds).contains(point) }
    }

    func clickDidLand(in clicked: NSWindow?, at point: NSPoint) {
        guard wantsKey(forClickIn: clicked, at: point), !panel.isKeyWindow else { return }
        panel.makeKey()
        if let top = handles.last(where: { $0.options.isModal }), !(panel.firstResponder is NSText) {
            panel.makeFirstResponder(Self.keyViews(in: top.content).first ?? top.content)
        }
    }

    /// A mouse event reached the panel. A move updates the routing; a click
    /// outside every interactive region (the panel had not let go yet) goes
    /// on to the parent window, and the panel lets go of the mouse.
    func panelMouseEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .mouseMoved, .mouseEntered, .mouseExited, .leftMouseDragged, .rightMouseDragged:
            routeMouse(at: NSEvent.mouseLocation)
            return false
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let point = event.locationInWindow
            guard !isAppHost, !acceptsMouse(at: point), let window else { return false }
            panel.ignoresMouseEvents = true
            // The window under the click: a page window there, else the parent.
            let screen = panel.convertPoint(toScreen: point)
            let target = (window.childWindows ?? []).reversed().first {
                Self.isPageWindow($0) && $0.isVisible && $0.frame.contains(screen)
            } ?? window
            if let forwarded = NSEvent.mouseEvent(with: event.type, location: target.convertPoint(fromScreen: screen),
                                                  modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                                  windowNumber: target.windowNumber, context: nil, eventNumber: event.eventNumber,
                                                  clickCount: event.clickCount, pressure: event.pressure) {
                target.sendEvent(forwarded)
            }
            return true
        default:
            return false
        }
    }

    func removeMouseMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    // MARK: Modal

    /// The panel takes the keyboard; Tab cycles inside the overlay (the
    /// panel's key view loop holds only overlay views); the previous key
    /// window and first responder are kept for `endModal`.
    func beginModal(_ handle: OverlayHandle) {
        if !handles.dropLast().contains(where: { $0.options.isModal }) {
            restoreWindow = NSApp.keyWindow ?? window
            restoreResponder = (NSApp.keyWindow ?? window)?.firstResponder
        }
        panel.acceptsKey = true
        // Tab and Shift-Tab cycle through this overlay's controls only.
        panel.autorecalculatesKeyViewLoop = false
        let keyViews = Self.keyViews(in: handle.content)
        for (index, view) in keyViews.enumerated() { view.nextKeyView = keyViews[(index + 1) % keyViews.count] }
        if panel.isVisible { panel.makeKey() }
        let first = keyViews.first ?? handle.content
        panel.initialFirstResponder = first
        panel.makeFirstResponder(first)
    }

    func endModal() {
        guard !handles.contains(where: { $0.options.isModal }) else {
            if let top = handles.last(where: { $0.options.isModal }) {
                panel.makeFirstResponder(Self.firstKeyView(in: top.content) ?? top.content)
            }
            return
        }
        let panelWasKey = panel.isKeyWindow
        panel.acceptsKey = false
        // Give the keyboard back only when the overlay still had it: after
        // the person clicked into the window and moved on, focus stays there.
        guard !isTearingDown, panelWasKey else {
            restoreWindow = nil
            restoreResponder = nil
            return
        }
        let window = restoreWindow ?? self.window
        if let window, window.isVisible { window.makeKey() }
        if let responder = restoreResponder, let window {
            // A field editor stands in for its text field; give the field back.
            if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSResponder {
                window.makeFirstResponder(field)
            } else {
                window.makeFirstResponder(responder)
            }
        }
        restoreWindow = nil
        restoreResponder = nil
    }

    /// Escape reaches the panel only while it is key (a modal overlay). For
    /// a non-modal overlay that dismisses on Escape, a local key monitor
    /// lives while such an overlay shows and catches an Escape for any of the
    /// app's windows; it goes with the last such overlay.
    func updateEscapeMonitor() {
        let wanted = handles.contains { $0.options.dismissOnEscape && !$0.options.isModal }
        if wanted, escapeMonitor == nil {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                      !self.panel.isKeyWindow, let target = event.window,
                      self.isAppHost || target === self.window || target.parent === self.window,
                      let handle = self.handles.last(where: { $0.options.dismissOnEscape && !$0.options.isModal }) else { return event }
                handle.dismiss()
                return nil
            }
        } else if !wanted, let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }

    /// Tab inside the newest modal overlay: the next (or previous) control, wrapping.
    func cycleKeyView(forward: Bool) -> Bool {
        guard let top = handles.last(where: { $0.options.isModal }) else { return false }
        let views = Self.keyViews(in: top.content)
        guard !views.isEmpty else { return true }
        var current = panel.firstResponder as? NSView
        if let editor = current as? NSTextView, editor.isFieldEditor { current = editor.delegate as? NSView }
        let index = current.flatMap { view in views.firstIndex { $0 === view } } ?? (forward ? views.count - 1 : 0)
        let next = views[(index + (forward ? 1 : views.count - 1)) % views.count]
        panel.makeFirstResponder(next)
        return true
    }

    /// Escape: the newest overlay that dismisses on Escape goes.
    func escape() {
        handles.last(where: { $0.options.dismissOnEscape })?.dismiss()
    }

    /// Controls that take the keyboard, in view order.
    static func keyViews(in view: NSView) -> [NSView] {
        var found: [NSView] = view.acceptsFirstResponder && view is NSControl ? [view] : []
        for child in view.subviews where !child.isHidden { found += keyViews(in: child) }
        return found
    }

    static func firstKeyView(in view: NSView) -> NSView? {
        if view.canBecomeKeyView { return view }
        for child in view.subviews {
            if let found = firstKeyView(in: child) { return found }
        }
        return nil
    }
}
