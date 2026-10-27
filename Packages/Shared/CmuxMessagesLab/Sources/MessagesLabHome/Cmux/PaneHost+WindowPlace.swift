import AppKit

// cmux: MessagesLab b6760b6. The typing indicator snaps to the window's device pixels from the rows' window
// place (RowCell.windowPlace). MessagesWindowView refreshes it on its own layout and scroll, and MessagesLab's
// host on each host layout and window change; Home also moves the transcript with no layout of it (a pane,
// split or sidebar container that moves without resizing it, a window's own later layout after a tab moved to
// it). Those moves happen in the window's layout pass: the app's host calls
// MessagesLabHomeView.windowDidLayout after each pass, and the rows refresh only when the place moved. Events
// with no layout (each key typed in the field) read nothing.
extension HostView {
    /// Every host layout (as MessagesLab's host): the rows read their place.
    /// `placeVideo`: the host's video layers follow the rows' snapped content (not on attach to a window,
    /// before the collection's layout: a playing row missing from the visible cells there would stop).
    func refreshWindowPlace(placeVideo: Bool = true) {
        guard let demo else { return }
        windowPlaceRefreshes += 1
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

    /// This host moved to another window (viewDidMoveToWindow): another window, another place.
    func windowPlaceDidChangeWindow() {
        lastWindowPlace = nil
        guard window != nil else { return }
        refreshWindowPlace(placeVideo: false)
    }
}

extension MessagesLabHomeView {
    /// The window finished a layout pass (CmuxNext: its `WindowLayoutPasses`): an ancestor may have
    /// moved the transcript without laying it out, so the rows read their place again if it moved.
    public func windowDidLayout() {
        guard window != nil else { return }
        controller.host.refreshWindowPlaceIfMoved()
    }
}
