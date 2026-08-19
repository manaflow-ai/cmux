import AppKit

extension SidebarTabDragSourceCoordinator {
    /// Builds the event passed to `beginDraggingSession` for `workspaceId`'s
    /// row. Prefers the live `NSApp.currentEvent` when it is the row's own mouse
    /// event; otherwise synthesizes a `.leftMouseDragged` at the gesture
    /// location. `location` is the gesture location in the modified row's local
    /// coordinate space, and the anchor overlay exactly covers that row, so the
    /// window-space conversion is exact.
    ///
    /// Returns nil when no *reliable* window can be resolved: the anchor's own
    /// window, the live event's window, or the cached window paired with the
    /// cached frame. There is deliberately no `NSApp.keyWindow` fallback — an
    /// unrelated key window would put the synthetic event (and the drag session
    /// `beginDrag` starts from it) in the wrong coordinate space. Callers treat
    /// nil as "no drag this gesture tick", failing closed.
    func dragEvent(for workspaceId: UUID, location: CGPoint) -> NSEvent? {
        guard let anchor = anchor(for: workspaceId) else { return nil }
        let windowFrame = windowFrame(for: workspaceId)
        let cachedWindow = cachedWindow(for: workspaceId)

        // Prefer the live event that drove this gesture: its location is
        // already in window base coordinates, so it stays correct even when a
        // re-render has detached the anchor overlay from its window.
        if let current = NSApp.currentEvent,
           current.type == .leftMouseDragged || current.type == .leftMouseDown,
           let eventWindow = current.window,
           anchor.window == nil || eventWindow === anchor.window {
            return current
        }

        // The window must be one of the reliable candidates: the anchor's own, or
        // the cached window the cached frame was captured in (the anchor can be
        // detached by a mid-drag re-render).
        guard let window = anchor.window ?? cachedWindow else { return nil }
        let locationInWindow: NSPoint
        if anchor.window === window {
            locationInWindow = anchor.convert(location, to: nil)
        } else if let windowFrame {
            // Anchor detached: map the row-local (top-left origin) gesture
            // offset over the window frame captured while it was attached.
            locationInWindow = NSPoint(
                x: windowFrame.minX + location.x,
                y: windowFrame.maxY - location.y
            )
        } else {
            return nil
        }
        let windowNumber = window.windowNumber
        if let event = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) {
            return event
        }
        // Last resort: a left-mouse-down is the one mouse event that always
        // constructs on every macOS version.
        return NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    }
}
