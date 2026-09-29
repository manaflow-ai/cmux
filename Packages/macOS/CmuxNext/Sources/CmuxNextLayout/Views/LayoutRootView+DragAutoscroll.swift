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
        guard local.y >= 0, local.y <= view.bounds.height else { return false }
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
        guard acceptsHorizontalScroll, !isUserScrolling, localX >= 0, localX <= bounds.width else { return false }
        let band = min(Self.autoscrollBand, bounds.width / 4)
        var speed: CGFloat = 0
        if localX < band { speed = -Self.autoscrollMaxSpeed * (1 - localX / band) }
        if localX > bounds.width - band { speed = Self.autoscrollMaxSpeed * (1 - (bounds.width - localX) / band) }
        guard speed != 0 else { return false }
        let target = ColumnStripGeometry.clamp(scroll.target + speed * CGFloat(dt), contentWidth: geometry.contentWidth, viewportWidth: bounds.width)
        guard abs(target - scroll.target) > 0.01 else { return false }
        scroll.target = target
        scroll.snap()
        reportScrollOnSettle = true
        applyPresentation()
        return true
    }
}
