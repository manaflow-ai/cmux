import AppKit

// The older top band keeps its drag (`reorder`) and ends it on its tile's mouse-up. A release that went to another
// window or the desktop never reaches the tile: the band sees it here, as the list does (`SidebarListView+PointerEnd`).
extension SidebarRegionView {
    /// Watches the app's releases while the region holds a drag: set with the drag, removed when it ends (any end).
    func followPointerEnd(from old: SidebarRegionDrag?) {
        guard old !== reorder else { return }
        if let old, let monitor = old.pointerEnd { NSEvent.removeMonitor(monitor); old.pointerEnd = nil }
        guard let drag = reorder else { return }
        drag.pointerEnd = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            // The region went away with its drag: the monitor goes too (the drag holds its token until then).
            guard let self else {
                if let monitor = drag.pointerEnd { NSEvent.removeMonitor(monitor); drag.pointerEnd = nil }
                return event
            }
            // A window's event is in its coordinates; one with no window (the desktop's) is on screen.
            self.releaseSeen(in: event.window, at: event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow)
            return event
        }
    }

    /// A left release anywhere in the app (`eventWindow`, at `screenPoint` on screen), before its window gets it. One sent
    /// to another window ends the drag after its dispatch, unless a panel forwarded it here (the drag ended then): the
    /// release point decides, as a tile's mouse-up does (`finishDrag(at:)`), so beside the sidebar the item comes off.
    func releaseSeen(in eventWindow: NSWindow?, at screenPoint: NSPoint) {
        guard let drag = reorder, eventWindow !== window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.reorder === drag, NSEvent.pressedMouseButtons & 1 == 0, let window = self.window else { return }
            self.finishDrag(at: window.convertPoint(fromScreen: screenPoint))
        }
    }
}
