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
        overlayIsStale = true
        flushOverlaySync()
    }

    /// Marks the overlay stale: it syncs once, at the end of the sync, frame
    /// or layout pass that runs now, else before this run-loop turn's
    /// frame commits. A pointer event, a drag frame or a scroll that moves
    /// several hosts syncs the plane once, not once per host or per pass.
    func setNeedsOverlaySync() {
        overlayIsStale = true
        guard !overlayFlushScheduled else { return }
        overlayFlushScheduled = true
        // Blocks run before the run loop waits, so before Core Animation
        // commits this turn's frame.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self] in
            MainActor.assumeIsolated { // main-proof: a CFRunLoopGetMain() block runs on the main thread
                guard let self else { return }
                self.overlayFlushScheduled = false
                self.flushOverlaySync()
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// Syncs the overlay when it is stale.
    func flushOverlaySync() {
        // A parked or hidden root keeps its overlay stale: nothing shows it, and it syncs once when it goes
        // live again (`setLive`).
        guard overlayIsStale, isLive else { return }
        syncOverlay()
    }

    /// Re-reads the plane's place and every ring's pane frame now. The
    /// window calls it after its layout pass while the plane lives in the
    /// overlay panel: an ancestor that moved this view (sidebar width) runs
    /// no layout of this view, and the panel is another window.
    /// Ring frames are in this view's coordinates, so only the plane's
    /// frame can go stale: the rings sync only when it moved.
    public func resyncOverlay() {
        if overlayPlane.syncFrame() { overlayIsStale = true }
        flushOverlaySync()
    }

    /// Places every displayed pane's ring and dim over its host, in this
    /// view's (= the plane's) coordinates, and reports interactive rects.
    /// Callers mark it stale and flush (`setNeedsOverlaySync`).
    ///
    /// O(what moved): a host whose frame, screen placement, covers, alpha and visibility, and this
    /// view's place in the window, are what they were at the last sync keeps its ring, dim and
    /// window frame as they are (no conversion, no strip notice). The hosts that changed are
    /// ``panesMovedInLastOverlaySync`` for the observers (`observeOverlaySync`).
    private func syncOverlay() {
        overlaySyncs += 1
        overlayIsStale = false
        let plane = overlayPlane
        let inWindow = window == nil ? nil : convert(bounds, to: nil)
        var shown: Set<ObjectIdentifier> = []
        var moved: Set<PaneID> = []
        for screen in screenViews.values where !screen.isHidden {
            let screenAlpha = screen.alphaValue
            let docks = screen.coverRects
            let above = screen.panesAbove()
            for host in screen.displayedHosts {
                let chrome = host.chrome
                shown.insert(ObjectIdentifier(chrome))
                // A ring never draws over a docked column (strip panes) or a pane in front of it.
                let covers = screen.ringCovers(of: host, docks: docks, above: above)
                let alpha = host.alphaValue * screenAlpha
                let key = PaneOverlaySyncKey(hostFrame: host.frame, screenFrame: screen.frame, screenBounds: screen.bounds,
                                             rootInWindow: inWindow, covers: covers, alpha: alpha, hidden: host.isHidden)
                if chrome.superview === plane, host.overlaySyncKey == key { continue }
                host.overlaySyncKey = key
                moved.insert(host.pane)
                if chrome.superview !== plane { plane.addSubview(chrome, positioned: .below, relativeTo: highlight) }
                let rect = convert(host.bounds, from: host)
                if chrome.frame != rect { chrome.frame = rect }
                chrome.setExcluded(covers.map { convert($0, from: screen).offsetBy(dx: -rect.minX, dy: -rect.minY) })
                if chrome.alphaValue != alpha { chrome.alphaValue = alpha }
                if chrome.isHidden != host.isHidden { chrome.isHidden = host.isHidden }
                host.noteWindowFrame()
                overlayHostsPlaced += 1
            }
        }
        for view in plane.subviews where view is PaneOverlayView && !shown.contains(ObjectIdentifier(view)) {
            view.removeFromSuperview()
        }
        panesMovedInLastOverlaySync = moved
        reportInteractiveRects()
        notifyOverlaySync()
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
        screenViews[active]?.refreshDividerHover()
    }

    /// Whether a layout motion runs (a split, close, zoom, New Column, column scroll): its springs
    /// move panes and dividers on every display frame until they land, including the frame they
    /// land in (``isLayoutInMotion``), or a change has started springs the display link has not
    /// stepped yet. A divider drag moves them under the pointer, not on a spring. The window keeps
    /// what follows the dividers only at rest (`WindowOverlayLayer`: divider catcher panels over
    /// pages), and hears the end once, after the landing frame's last sync (`setLayoutInMotion`).
    public var isInLayoutMotion: Bool {
        isLayoutInMotion || screenViews.values.contains { !$0.isHidden && $0.hasMotion }
    }

    func reportInteractiveRects() {
        guard let planeHost else { return }
        let rects = interactiveOverlayRects
        let areas = dividerMouseAreas
        let moving = isInLayoutMotion
        guard rects != reportedInteractiveRects || areas != reportedDividerMouseAreas || moving != reportedLayoutMotion else { return }
        reportedInteractiveRects = rects
        reportedDividerMouseAreas = areas
        reportedLayoutMotion = moving
        planeHost.interactiveOverlayRectsDidChange(overlayPlane)
    }

    /// Displayed pane rings, for `debug.layers`: pane id, the pane's frame
    /// in window coordinates, whether the ring shows, the rect the ring
    /// strokes and the pane's rounded content rect it must equal (both in
    /// window coordinates; the plane has the root's coordinates wherever it
    /// lives, so the ring rect is read from the overlay itself).
    /// `ringInSync`: the two rects agree within ``ringSyncTolerance`` (they
    /// come through different coordinate conversions, so a fractional pane
    /// size gives rounding noise near 1e-13 pt, not a lag).
    public var overlayRings: [(pane: String, frameInWindow: CGRect, showsRing: Bool, ringInWindow: CGRect, contentInWindow: CGRect,
                               ringInSync: Bool)] {
        guard let active = model.activeScreenID, let screen = screenViews[active], window != nil else { return [] }
        return screen.displayedHosts.map { host in
            let chrome = host.chrome
            let ring = convert(chrome.ringFrame.offsetBy(dx: chrome.frame.minX, dy: chrome.frame.minY), to: nil)
            let content = host.convert(host.roundedRect, to: nil)
            return (host.pane.rawValue, host.convert(host.bounds, to: nil), chrome.showsRing && !chrome.isHidden,
                    ring, content, Self.ringRectsMatch(ring, content))
        }
    }

    /// The first shown ring off its pane's content rect (``overlayRings`` filtered), converting only
    /// the rings that show: the overlay layer reads it after every layout pass of the root.
    public var laggingRing: (pane: String, ringInWindow: CGRect, contentInWindow: CGRect)? {
        guard let active = model.activeScreenID, let screen = screenViews[active], window != nil else { return nil }
        for host in screen.displayedHosts where host.chrome.showsRing && !host.chrome.isHidden {
            let chrome = host.chrome
            let ring = convert(chrome.ringFrame.offsetBy(dx: chrome.frame.minX, dy: chrome.frame.minY), to: nil)
            let content = host.convert(host.roundedRect, to: nil)
            if !Self.ringRectsMatch(ring, content) { return (host.pane.rawValue, ring, content) }
        }
        return nil
    }

    /// Far below a device pixel (0.5 pt at 2x), far above conversion noise.
    public static let ringSyncTolerance: CGFloat = 0.001

    static func ringRectsMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= ringSyncTolerance && abs(a.minY - b.minY) <= ringSyncTolerance
            && abs(a.width - b.width) <= ringSyncTolerance && abs(a.height - b.height) <= ringSyncTolerance
    }

    /// The drop highlight's material (`debug.layers`), and a pin for it
    /// (`debug.drop_highlight`; nil follows this Mac).
    public var dropHighlightMaterial: OverlayMaterial { highlight.material }
    public func pinDropHighlightMaterial(_ material: OverlayMaterial?) { highlight.pinMaterial(material) }
    /// The drop overlay style drawing now (`drop.overlay.style`).
    public var dropHighlightStyle: DropOverlayStyle { highlight.style }

    /// Whether the drop highlight is showing, and the outline ring's opacity
    /// as drawn (nil for another style): a hidden ring that came back after
    /// a drop shows here (`debug.drop_highlight` `report`).
    public var dropHighlightShowing: Bool { highlight.isShowing }
    public var dropRingOpacity: Float? { highlight.outline?.ringOpacity }

    /// The drop highlight's target rect in window coordinates while it shows.
    public var dropHighlightFrameInWindow: CGRect? {
        guard highlight.isShowing, window != nil else { return nil }
        return highlight.convert(highlight.targetRect, to: nil)
    }
}
