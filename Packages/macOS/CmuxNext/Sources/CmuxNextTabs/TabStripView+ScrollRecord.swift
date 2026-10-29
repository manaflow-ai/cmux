public import AppKit

// The strip's scroll in a remount record (`WorkspaceViewRecord`): saved when its
// workspace unmounts, given back to the new strip before its first frame.
extension TabStripView {
    /// Where the strip's scroll settles (`scrollOffset` is the target of any reveal in flight).
    public var restorableScrollOffset: CGFloat { scrollOffset }

    /// Rests the strip at `offset`. Before its first layout the offset waits there and that
    /// layout's `relayout` clamps it to the tabs; once laid out it clamps and places them now.
    public func restoreScrollOffset(_ offset: CGFloat) {
        guard viewportWidth > 0 else {
            scrollOffset = max(0, offset)
            return
        }
        let clamped = TabScrollMath.clamp(offset, contentWidth: result.contentWidth, viewportWidth: viewportWidth)
        guard clamped != scrollOffset else { return }
        let from = scrollMapping
        scrollOffset = clamped
        applyFrames(scrollFrom: from)
    }
}
