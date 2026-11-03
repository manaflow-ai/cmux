import AppKit

// cmux: MessagesLab b6760b6. The typing indicator snaps to the window's device pixels from the rows' window
// place (RowCell.windowPlace). MessagesWindowView refreshes it on its own layout and scroll, and MessagesLab's
// host on each host layout and window change; Home also moves the transcript with no layout of it (a pane,
// split or sidebar container that moves without resizing it, a window's own later layout after a tab moved to
// it). So the host reads the place again after each pass of the window's event loop
// (NSWindow.didUpdateNotification) and refreshes the rows only when it moved.
extension HostView {
    /// Every host layout (as MessagesLab's host): the rows read their place.
    /// `placeVideo`: the host's video layers follow the rows' snapped content (not on attach to a window,
    /// before the collection's layout: a playing row missing from the visible cells there would stop).
    func refreshWindowPlace(placeVideo: Bool = true) {
        guard let demo else { return }
        let p = demo.windowPlace
        lastWindowPlace = (p.origin, p.axis)
        demo.refreshWindowPlace()
        if placeVideo { controller?.intents?.rowsPlaced() }
    }

    /// The rows read their place only when it moved since they last did (two layer conversions otherwise).
    func refreshWindowPlaceIfMoved() {
        guard let demo else { return }
        let p = demo.windowPlace
        if let last = lastWindowPlace, last.origin == p.origin, last.axis == p.axis { return }
        refreshWindowPlace()
    }

    /// Follows this host's window (viewDidMoveToWindow): after each update of that window, the place is
    /// read again. Block form on queue .main (the crash program's objc_observer rule).
    func observeWindowPlace() {
        windowPlaceObserver.map(NotificationCenter.default.removeObserver)
        windowPlaceObserver = nil
        lastWindowPlace = nil
        guard let window else { return }
        windowPlaceObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window,
                                                                     queue: .main) { [weak self] _ in
            self?.refreshWindowPlaceIfMoved()
        }
        refreshWindowPlace(placeVideo: false)
    }
}
