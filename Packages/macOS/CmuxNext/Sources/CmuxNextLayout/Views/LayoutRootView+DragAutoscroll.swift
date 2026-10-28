public import AppKit

/// The edge auto-scroll a tab drag asks for where its pointer is: which columns screen scrolls and
/// how fast. The drag resolves it once per pointer delivery (``LayoutRootView/tabDragAutoscroll(locationInWindow:)``)
/// and steps it once per display frame (``LayoutRootView/stepTabDragAutoscroll(_:dt:)``), so a frame
/// with no pointer event does no hit test: the screen view does not move under a resting pointer, so
/// the speed holds until the pointer moves. Chromium's drag autoscroll works the same way: the
/// target is set from the pointer event, a timer scrolls it
/// (`third_party/blink/renderer/core/page/autoscroll_controller.cc`, `UpdateDragAndDrop`, `Animate`).
public nonisolated struct TabDragAutoscroll: Equatable, Sendable {
    /// The columns screen that scrolls.
    public let screen: ScreenID
    /// Points per second; negative toward the leading edge.
    public let speed: CGFloat
}

/// Edge auto-scroll of a columns screen while an in-process tab drag hovers
/// near its leading or trailing edge, so a drag can reach off-screen
/// columns. Nothing runs between drags.
extension LayoutRootView {
    /// The auto-scroll a drag at `locationInWindow` asks for; nil outside the active columns
    /// screen's edge bands.
    public func tabDragAutoscroll(locationInWindow: NSPoint) -> TabDragAutoscroll? {
        guard let hit = tabDragAutoscrollScreen(at: locationInWindow), let speed = hit.view.edgeAutoscrollSpeed(localX: hit.local.x) else { return nil }
        return TabDragAutoscroll(screen: hit.screen, speed: speed)
    }

    /// One frame of `autoscroll`, `dt` seconds long. Returns true when it scrolled (hit-test the
    /// drag again: content moved under the pointer). A screen no longer shown does not scroll.
    @discardableResult
    public func stepTabDragAutoscroll(_ autoscroll: TabDragAutoscroll, dt: Double) -> Bool { // perf-hot: 2ms drag-frame (every frame of a drag)
        guard let view = tabDragAutoscrollView(autoscroll), view.stepEdgeAutoscroll(speed: autoscroll.speed, dt: dt) else { return false }
        driver.start()
        return true
    }

    /// Whether `autoscroll` scrolls its screen now (shown, no gesture holds it, not at that end): the
    /// drag session runs its frame clock only then (Chrome's tab drag auto-scroll timer runs only in the
    /// edge zone, chrome/browser/ui/views/tabs/tab_drag_controller.cc `StartScrollingTimer`).
    public func tabDragAutoscrolls(_ autoscroll: TabDragAutoscroll) -> Bool {
        tabDragAutoscrollView(autoscroll)?.edgeAutoscrollTarget(speed: autoscroll.speed, dt: 1.0 / 60) != nil
    }

    /// The screen `autoscroll` scrolls, while it is the active one and shown.
    private func tabDragAutoscrollView(_ autoscroll: TabDragAutoscroll) -> ScreenContentView? {
        guard model.activeScreenID == autoscroll.screen, let view = screenViews[autoscroll.screen], !view.isHidden else { return nil }
        return view
    }

    /// The active columns screen and the point in it, when the point is over the strip's
    /// uncovered range: a drag over a top or bottom dock drops there and never scrolls the strip.
    private func tabDragAutoscrollScreen(at locationInWindow: NSPoint) -> (screen: ScreenID, view: ScreenContentView, local: NSPoint)? {
        guard let active = model.activeScreenID, let view = screenViews[active], !view.isHidden else { return nil }
        let local = view.convert(locationInWindow, from: nil)
        let range = view.uncoveredRect
        guard local.y >= range.minY, local.y <= range.maxY else { return nil }
        return (active, view, local)
    }
}

extension ScreenContentView {
    /// Width of the edge band that scrolls, and the top speed in points per
    /// second at the very edge.
    static let autoscrollBand: CGFloat = 56
    static let autoscrollMaxSpeed: CGFloat = 1400

    /// The scroll speed at `localX`: it grows toward the edge; nil outside the edge bands.
    func edgeAutoscrollSpeed(localX: CGFloat) -> CGFloat? {
        // The bands sit at the edges of the strip's uncovered range, so a
        // drag next to a docked column scrolls and one over it drops.
        let range = uncoveredRect
        guard acceptsHorizontalScroll, localX >= range.minX, localX <= range.maxX else { return nil }
        let x = localX - range.minX
        let band = min(Self.autoscrollBand, range.width / 4)
        var speed: CGFloat = 0
        if x < band { speed = -Self.autoscrollMaxSpeed * (1 - x / band) }
        if x > range.width - band { speed = Self.autoscrollMaxSpeed * (1 - (range.width - x) / band) }
        return speed == 0 ? nil : speed
    }

    /// Scrolls the strip by `speed` for `dt` seconds; false when it cannot move (a gesture holds
    /// the strip, or the strip is at its end).
    func stepEdgeAutoscroll(speed: CGFloat, dt: Double) -> Bool {
        guard let target = edgeAutoscrollTarget(speed: speed, dt: dt) else { return false }
        cpuTakesCamera()
        scroll.target = target
        scroll.snap()
        reportScrollOnSettle = true
        applyPresentation()
        return true
    }

    /// The scroll target after `dt` at `speed`; nil when a gesture holds the strip or it is already
    /// at that end.
    func edgeAutoscrollTarget(speed: CGFloat, dt: Double) -> CGFloat? {
        guard acceptsHorizontalScroll, !isUserScrolling else { return nil }
        let target = ColumnStripGeometry.clamp(scroll.target + speed * CGFloat(dt), contentWidth: geometry.contentWidth,
                                               viewportWidth: geometry.stripWidth)
        guard abs(target - scroll.target) > 0.01 else { return nil }
        return target
    }
}
