public import AppKit

extension TabGroupID {
    /// This group's chip in `strip`, in screen coordinates, for popups that
    /// open beside it (the App's icon picker; the group editor computes the
    /// same frame). Nil when the strip is not in a window or draws no chip
    /// for the group. Not on `TabStripView`: its line budget is frozen.
    @MainActor
    public func chipFrameOnScreen(in strip: TabStripView) -> NSRect? {
        guard let chip = strip.groups.chips[self], let window = strip.window else { return nil }
        return window.convertToScreen(strip.tabsClip.convert(strip.scroller.shownFrame(chip.layer), to: nil))
    }
}
