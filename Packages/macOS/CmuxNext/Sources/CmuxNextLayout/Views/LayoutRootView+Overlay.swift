public import AppKit
public import CmuxNextDesign

/// The overlay plane: pane rings and dims follow their hosts' displayed
/// frames, and the rects of overlays that take the mouse are reported.
extension LayoutRootView {
    /// Puts the plane back as the topmost subview of this view.
    public func returnPlaneHome() {
        if overlayPlane.superview !== self {
            addSubview(overlayPlane)
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
            let covers = screen.coverRects.map { convert($0, from: screen) }
            for host in screen.displayedHosts {
                let chrome = host.chrome
                if chrome.superview !== plane { plane.addSubview(chrome, positioned: .below, relativeTo: highlight) }
                let rect = convert(host.bounds, from: host)
                if chrome.frame != rect { chrome.frame = rect }
                // A strip pane's ring never draws over a docked column.
                chrome.setExcluded(screen.isStripHost(host) ? covers.map { $0.offsetBy(dx: -rect.minX, dy: -rect.minY) } : [])
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
        onOverlaySync?()
    }

    /// Rects (this view's coordinates) where native overlays in the root
    /// draw: divider lines. Content drawn above the window (Chromium pages) must leave
    /// these uncovered. A divider's wider hit area is not here: it draws
    /// nothing over panes (`dividerMouseAreas`).
    public var interactiveOverlayRects: [CGRect] {
        var rects: [CGRect] = []
        if let active = model.activeScreenID, let screen = screenViews[active], !screen.isHidden {
            rects += screen.dividerLineRects.map { convert($0, from: screen) }
        }
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

    /// Displayed pane rings, for `debug.layers`: pane id, the pane's frame
    /// in window coordinates, whether the ring shows, the rect the ring
    /// strokes and the pane's rounded content rect it must equal (both in
    /// window coordinates; the plane has the root's coordinates wherever it
    /// lives, so the ring rect is read from the overlay itself).
    public var overlayRings: [(pane: String, frameInWindow: CGRect, showsRing: Bool, ringInWindow: CGRect, contentInWindow: CGRect)] {
        guard let active = model.activeScreenID, let screen = screenViews[active], window != nil else { return [] }
        return screen.displayedHosts.map { host in
            let chrome = host.chrome
            let ring = chrome.ringFrame.offsetBy(dx: chrome.frame.minX, dy: chrome.frame.minY)
            return (host.pane.rawValue, host.convert(host.bounds, to: nil), chrome.showsRing && !chrome.isHidden,
                    convert(ring, to: nil), host.convert(host.roundedRect, to: nil))
        }
    }

    /// The drop highlight's material (`debug.layers`), and a pin for it
    /// (`debug.drop_highlight`; nil follows this Mac).
    public var dropHighlightMaterial: OverlayMaterial { highlight.material }
    public func pinDropHighlightMaterial(_ material: OverlayMaterial?) { highlight.pinMaterial(material) }
    /// The drop overlay style drawing now (`drop.overlay.style`).
    public var dropHighlightStyle: DropOverlayStyle { highlight.style }

    /// The drop highlight's target rect in window coordinates while it shows.
    public var dropHighlightFrameInWindow: CGRect? {
        guard highlight.isShowing, window != nil else { return nil }
        return highlight.convert(highlight.targetRect, to: nil)
    }
}
