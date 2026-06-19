import AppKit

extension CanvasRootView {
    func installPaneBodyFocusMonitor() {
        guard paneBodyFocusMonitor == nil else { return }
        paneBodyFocusMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self,
                  let window = self.window,
                  event.window === window else {
                return event
            }

            _ = self.focusPaneBody(for: event, in: window)
            return event
        }
    }

    func removePaneBodyFocusMonitor() {
        if let paneBodyFocusMonitor {
            NSEvent.removeMonitor(paneBodyFocusMonitor)
        }
        paneBodyFocusMonitor = nil
    }

    @discardableResult
    func focusPaneBody(for event: NSEvent, in _: NSWindow) -> Bool {
        let location = convert(event.locationInWindow, from: nil)
        return focusPaneBody(fromRootMouseDownAt: location)
    }

    @discardableResult
    func focusPaneBody(fromRootMouseDownAt point: CGPoint) -> Bool {
        guard bounds.contains(point),
              !pointTargetsCanvasOverlay(point) else {
            return false
        }
        return focusPaneBody(at: point)
    }

    @discardableResult
    func focusPaneBody(at point: CGPoint) -> Bool {
        guard isWorkspaceVisible else { return false }
        guard let paneView = paneBodyView(at: point) else { return false }
        paneViewDidRequestFocus(paneView)
        return true
    }

    private func pointTargetsCanvasOverlay(_ point: CGPoint) -> Bool {
        if rootPoint(point, targetsOverlay: minimapView) {
            return true
        }
        if rootPoint(point, targetsOverlay: commandScrollHintHost) {
            return true
        }
        return false
    }

    private func rootPoint(_ point: CGPoint, targetsOverlay overlay: NSView?) -> Bool {
        guard let overlay, !overlay.isHidden, let container = overlay.superview else { return false }
        let containerPoint = container.convert(point, from: self)
        guard let hitView = container.hitTest(containerPoint) else { return false }
        return hitView === overlay || hitView.isDescendant(of: overlay)
    }

    private func paneBodyView(at point: CGPoint) -> CanvasPaneView? {
        let documentPoint = documentView.convert(point, from: self)
        for pane in model.layout.panes.reversed() {
            guard let view = paneViews[pane.id], view.frame.contains(documentPoint) else { continue }
            let localPoint = view.convert(documentPoint, from: documentView)
            // Stop at the first pane frame hit: chrome and resize-rim clicks
            // belong to that frontmost pane, not an overlapped pane behind it.
            return view.containsBodyPoint(localPoint) ? view : nil
        }
        return nil
    }
}
