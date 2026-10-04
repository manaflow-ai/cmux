public import AppKit

public extension WindowOverlayHost {
    /// Shows `content` above every page of the window. `content` keeps its
    /// frame size (its fitting size when it has none); the kind and anchor
    /// decide where it goes.
    func present(_ content: NSView, options: OverlayOptions) -> OverlayHandle {
        let handle = OverlayHandle(id: nextID, content: content, options: options, host: self)
        nextID += 1
        if content.frame.size == .zero { content.setFrameSize(content.fittingSize) }
        if options.dimsContent, !isAppHost {
            let scrim = OverlayScrimView(frame: panel.overlayContainer.bounds)
            scrim.identifier = NSUserInterfaceItemIdentifier("overlay-scrim-\(handle.id)")
            panel.overlayContainer.addSubview(scrim)
        }
        content.removeFromSuperview()
        panel.overlayContainer.addSubview(content)
        handles.append(handle)
        syncPanel()
        layout(handle)
        if options.isModal { beginModal(handle) }
        updateMouseRouting()
        return handle
    }

    /// Whether the panel takes the mouse at `point` (window coordinates):
    /// over a modal or dimming overlay's window, a modal region, or an
    /// overlay that does not pass clicks through.
    func acceptsMouse(at point: NSPoint) -> Bool {
        interactiveRegions().contains { $0.contains(point) }
    }

    /// Input-blocking rects, window coordinates.
    func interactiveRegions() -> [NSRect] {
        let bounds = panel.overlayContainer.bounds
        return handles.flatMap { handle -> [NSRect] in
            let options = handle.options
            if options.isModal || options.dimsContent { return [bounds] }
            var rects: [NSRect] = []
            if let region = options.modalRegion { rects.append(region) }
            if !options.passesThroughClicks { rects.append(handle.content.frame) }
            return rects
        }
    }
}

extension WindowOverlayHost {
    func remove(_ handle: OverlayHandle) {
        handles.removeAll { $0 === handle }
        handle.content.removeFromSuperview()
        panel.overlayContainer.subviews
            .filter { $0.identifier?.rawValue == "overlay-scrim-\(handle.id)" }
            .forEach { $0.removeFromSuperview() }
        if handle.options.isModal { endModal() }
        updateMouseRouting()
        syncPanel()
    }

    /// Places `handle` in panel coordinates, which are the window's own.
    func layout(_ handle: OverlayHandle) {
        if isAppHost { return layoutAppPanel() }
        let bounds = panel.overlayContainer.bounds.isEmpty ? (window?.contentView?.bounds ?? .zero) : panel.overlayContainer.bounds
        handle.content.setFrameOrigin(Self.origin(for: handle.content.frame.size, options: handle.options, in: bounds))
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
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
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
                                                                   .otherMouseDragged, .mouseEntered, .mouseExited]) { [weak self] event in
            self?.routeMouse(at: NSEvent.mouseLocation)
            return event
        }
    }

    func routeMouse(at screenPoint: NSPoint) {
        let point = panel.frame.isEmpty ? screenPoint : panel.convertPoint(fromScreen: screenPoint)
        let accepts = acceptsMouse(at: point)
        if panel.ignoresMouseEvents == accepts { panel.ignoresMouseEvents = !accepts }
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
        panel.acceptsKey = false
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
