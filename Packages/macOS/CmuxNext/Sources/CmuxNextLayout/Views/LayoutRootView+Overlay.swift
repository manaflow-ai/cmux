public import AppKit

/// The overlay plane: pane rings and dims follow their hosts' displayed
/// frames, and the rects of overlays that take the mouse are reported.
extension LayoutRootView {
    /// Puts the plane back as a subview of this view, below the screen
    /// switcher (which takes clicks and stays in the root).
    public func returnPlaneHome() {
        if overlayPlane.superview !== self {
            addSubview(overlayPlane, positioned: .below, relativeTo: switcher)
        }
        overlayPlane.syncFrame()
        syncOverlay()
    }

    /// Places every displayed pane's ring and dim over its host, in this
    /// view's (= the plane's) coordinates, and reports interactive rects.
    func syncOverlay() {
        let plane = overlayPlane
        var shown: Set<ObjectIdentifier> = []
        for screen in screenViews.values where !screen.isHidden {
            let screenAlpha = screen.alphaValue
            for host in screen.displayedHosts {
                let chrome = host.chrome
                if chrome.superview !== plane { plane.addSubview(chrome, positioned: .below, relativeTo: highlight) }
                let rect = convert(host.bounds, from: host)
                if chrome.frame != rect { chrome.frame = rect }
                let alpha = host.alphaValue * screenAlpha
                if chrome.alphaValue != alpha { chrome.alphaValue = alpha }
                if chrome.isHidden != host.isHidden { chrome.isHidden = host.isHidden }
                host.noteWindowFrame()
                shown.insert(ObjectIdentifier(chrome))
            }
        }
        for view in plane.subviews where view is PaneOverlayView && !shown.contains(ObjectIdentifier(view)) {
            view.removeFromSuperview()
        }
        reportInteractiveRects()
    }

    /// Rects (this view's coordinates) where native overlays in the root
    /// draw: divider lines and the screen switcher (which also takes the
    /// mouse). Content drawn above the window (Chromium pages) must leave
    /// these uncovered. A divider's wider hit area is not here: it draws
    /// nothing over panes (`dividerMouseAreas`).
    public var interactiveOverlayRects: [CGRect] {
        var rects: [CGRect] = []
        if let active = model.activeScreenID, let screen = screenViews[active], !screen.isHidden {
            rects += screen.dividerLineRects.map { convert($0, from: screen) }
        }
        if !switcher.isHidden, switcher.frame.width > 0 { rects.append(switcher.frame) }
        return rects
    }

    /// Divider and column edge hit areas of the active screen, in this
    /// view's coordinates. Over a Chromium page the App covers them with a
    /// click-catching panel that forwards the mouse to this window, so the
    /// page keeps drawing edge to edge under them.
    public var dividerMouseAreas: [LayoutMouseArea] {
        guard let active = model.activeScreenID, let screen = screenViews[active], !screen.isHidden else { return [] }
        return screen.dividerMouseAreas.map { area in
            var area = area
            area.rect = convert(area.rect, from: screen)
            return area
        }
    }

    /// Shows or hides a divider's hover line for a pointer that is over a
    /// click-catching panel above a page.
    public func setDividerHovered(_ id: String, _ hovered: Bool) {
        guard let active = model.activeScreenID else { return }
        screenViews[active]?.setDividerHovered(id, hovered)
    }

    private func reportInteractiveRects() {
        guard let planeHost else { return }
        let rects = interactiveOverlayRects
        let areas = dividerMouseAreas
        guard rects != reportedInteractiveRects || areas != reportedDividerMouseAreas else { return }
        reportedInteractiveRects = rects
        reportedDividerMouseAreas = areas
        planeHost.interactiveOverlayRectsDidChange(overlayPlane)
    }

    /// Displayed pane rings, for `debug.layers`: pane id, frame in window
    /// coordinates, and whether the ring shows.
    public var overlayRings: [(pane: String, frameInWindow: CGRect, showsRing: Bool)] {
        guard let active = model.activeScreenID, let screen = screenViews[active], window != nil else { return [] }
        return screen.displayedHosts.map { host in
            (host.pane.rawValue, host.convert(host.bounds, to: nil), host.chrome.showsRing && !host.chrome.isHidden)
        }
    }

    /// The drop highlight's frame in window coordinates while it shows.
    public var dropHighlightFrameInWindow: CGRect? {
        guard highlight.isShowing, window != nil else { return nil }
        return convert(highlight.frame, to: nil)
    }
}
