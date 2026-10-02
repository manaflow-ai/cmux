import AppKit
import CmuxNextDesign

/// The strip scrollbar (sticky-column.md, B1 to B5): placed along the
/// bottom of the strip's uncovered range, fed the presented offset each
/// frame, and driving the scroll reducer like a trackpad gesture (thumb
/// drag) or a wheel notch (track click).
extension ScreenContentView {
    func updateScrollbar() {
        let mode = context.model.stripScrollbar
        guard geometry.isColumns, mode != .off, bounds.width > 0, bounds.height > 0 else {
            scrollbar?.isHidden = true
            scrollbarOffset = nil
            return
        }
        let bar = scrollbar ?? makeScrollbar()
        if bar.isHidden { bar.isHidden = false }
        let uncovered = uncoveredRect
        let inset = Metrics.space4
        let height = StripScrollbarView.bandHeight
        let band = CGRect(x: uncovered.minX + inset, y: bounds.height - height, width: max(0, uncovered.width - inset * 2), height: height)
        let offset = scroll.value
        // Only scrolling flashes it (a spring step or a reveal that snapped in
        // its place, a gesture, the wheel, the scrollbar); a resize or layout
        // change that moves the offset does not.
        let scrolled = scrollbarFlash && (scrollbarOffset.map { abs($0 - offset) > 0.25 } ?? true)
        scrollbarFlash = false
        scrollbarOffset = offset
        bar.update(StripScrollbarView.Input(mode: mode, band: band, offset: offset, contentWidth: geometry.contentWidth,
                                            viewportWidth: geometry.stripWidth, snaps: geometry.snapOffsets),
                   scrolled: scrolled)
    }

    private func makeScrollbar() -> StripScrollbarView {
        let bar = StripScrollbarView(hideClock: context.scrollbarClock)
        addSubview(bar)
        scrollbar = bar
        bar.onDragBegan = { [weak self] in
            guard let self else { return }
            self.beginUserScroll()
        }
        bar.onDrag = { [weak self] offset in
            guard let self, let raw = self.scrollState.gesture?.raw else { return }
            self.userScroll(deltaX: raw - offset, timestamp: ProcessInfo.processInfo.systemUptime)
            self.context.requestFrames()
        }
        bar.onDragEnded = { [weak self] in
            guard let self else { return }
            self.endUserScroll(timestamp: ProcessInfo.processInfo.systemUptime)
            self.context.requestFrames()
        }
        bar.onPage = { [weak self] target in
            guard let self else { return }
            self.page(to: target)
            self.context.requestFrames()
        }
        return bar
    }

    /// The scrollbar's state for `debug.sticky`: mode, shown, thumb and
    /// band (local coordinates).
    var scrollbarReport: (shown: Bool, thumb: CGRect?, band: CGRect)? {
        guard let scrollbar, !scrollbar.isHidden else { return nil }
        return (scrollbar.isShown, scrollbar.thumbRect.map { $0.offsetBy(dx: scrollbar.frame.minX, dy: scrollbar.frame.minY) },
                scrollbar.frame)
    }
}
