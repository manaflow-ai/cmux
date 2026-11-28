public import AppKit

/// Edge auto-scroll of a columns screen while an in-process tab drag hovers
/// near its leading or trailing edge, so a drag can reach off-screen
/// columns. The drag session calls it once per display frame; nothing runs
/// between drags.
extension LayoutRootView {
    /// Scrolls the active columns screen when `locationInWindow` sits in an
    /// edge band. Speed grows toward the edge. Returns true when it scrolled
    /// (call `updateTabDrag` again: content moved under the pointer).
    @discardableResult
    public func autoscrollTabDrag(locationInWindow: NSPoint, dt: Double) -> Bool {
        guard let active = model.activeScreenID, let view = screenViews[active], !view.isHidden else { return false }
        let local = view.convert(locationInWindow, from: nil)
        // Only over the strip's uncovered range: a drag over a top or bottom
        // dock drops there and never scrolls the strip.
        let range = view.uncoveredRect
        guard local.y >= range.minY, local.y <= range.maxY else { return false }
        guard view.edgeAutoscroll(localX: local.x, dt: dt) else { return false }
        driver.start()
        return true
    }
}

extension ScreenContentView {
    /// Width of the edge band that scrolls, and the top speed in points per
    /// second at the very edge.
    static let autoscrollBand: CGFloat = 56
    static let autoscrollMaxSpeed: CGFloat = 1400

    func edgeAutoscroll(localX: CGFloat, dt: Double) -> Bool {
        // The bands sit at the edges of the strip's uncovered range, so a
        // drag next to a docked column scrolls and one over it drops.
        let range = uncoveredRect
        guard acceptsHorizontalScroll, !isUserScrolling, localX >= range.minX, localX <= range.maxX else { return false }
        let x = localX - range.minX
        let band = min(Self.autoscrollBand, range.width / 4)
        var speed: CGFloat = 0
        if x < band { speed = -Self.autoscrollMaxSpeed * (1 - x / band) }
        if x > range.width - band { speed = Self.autoscrollMaxSpeed * (1 - (range.width - x) / band) }
        guard speed != 0 else { return false }
        let target = ColumnStripGeometry.clamp(scroll.target + speed * CGFloat(dt), contentWidth: geometry.contentWidth,
                                               viewportWidth: geometry.stripWidth)
        guard abs(target - scroll.target) > 0.01 else { return false }
        scroll.target = target
        scroll.snap()
        reportScrollOnSettle = true
        applyPresentation()
        return true
    }
}
