import AppKit

// The older top band keeps its drag (`reorder`) and ends it on its tile's mouse-up. A release that went to another
// window or the desktop never reaches the tile: the band sees it here, as the list does (`SidebarListView+PointerEnd`).
extension SidebarRegionView {
    /// Watches the app's releases while the region holds a drag: set with the drag, removed when it ends (any end, leaving
    /// its window too: `viewWillMove(toWindow:)`). The monitor holds neither the region nor the drag.
    func followPointerEnd(from old: SidebarRegionDrag?) {
        guard old !== reorder else { return }
        if let old { Self.stopFollowing(old) }
        guard let drag = reorder else { return }
        var token: Any?
        token = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self, weak drag] event in
            guard let self, let drag, self.reorder === drag, self.window != nil else {
                // The region or its drag went away without an end: the monitor goes at its first release since.
                if let monitor = token { NSEvent.removeMonitor(monitor); token = nil }
                return event
            }
            // A window's event is in its coordinates; one with no window (the desktop's) is on screen.
            self.releaseSeen(in: event.window, at: event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow)
            return event
        }
        drag.pointerEnd = token
    }

    static func stopFollowing(_ drag: SidebarRegionDrag) {
        if let monitor = drag.pointerEnd { NSEvent.removeMonitor(monitor); drag.pointerEnd = nil }
    }

    /// Off its window no release can end the drag: it ends now, removing and moving nothing. Its monitor goes with
    /// it (`reorder`'s `didSet`), its card leaves and its views show again, with no landing (nothing draws it).
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil, let drag = reorder else { return }
        reorder = nil
        _ = dropToListProbe?(nil)
        reorderSections = nil
        drag.lift.removeFromSuperview()
        for view in drag.hidden { view.alphaValue = 1 }
        relayout(animated: false)
    }

    /// A left release anywhere in the app (`eventWindow`, at `screenPoint` on screen), before its window gets it. One sent
    /// to another window ends the drag after its dispatch, unless a panel forwarded it here (the drag ended then): the
    /// release point decides, as a tile's mouse-up does (`finishDrag(at:)`), so beside the sidebar the item comes off.
    func releaseSeen(in eventWindow: NSWindow?, at screenPoint: NSPoint) {
        guard let drag = reorder, eventWindow !== window else { return }
        // task-owner: one hop after the release's dispatch; ends at once (the drag it names may be gone)
        Task { @MainActor [weak self] in
            guard let self, self.reorder === drag, NSEvent.pressedMouseButtons & 1 == 0, let window = self.window else { return }
            self.finishDrag(at: window.convertPoint(fromScreen: screenPoint))
        }
    }
}
