import AppKit

// The pane's "…" (`PaneToolbar`) sits at the strip's trailing end, as wide as it needs: the strip
// gives up that width, in the pane's frame layout (`layout()`) and on a browser's band (R109,
// `PaneContentView.bandFrames`) alike.
extension PaneContentView {
    func installToolbar(replacing old: PaneToolbar?) {
        guard toolbar !== old else { return }
        // VoiceOver's band order names the toolbar: it is made again for the new one.
        let banded = isBandActive
        if banded { releaseBand() }
        old?.view.removeFromSuperview()
        if let view = toolbar?.view { addSubview(view, positioned: .above, relativeTo: stripView); view.stripFrame = { [weak self] in self?.stripView.frame } }
        if banded { updateBand() }
        needsLayout = true // invalidate: another toolbar (the guard above); the strip gives up its width.
    }

    /// "…"'s width beside a strip `shown` tall (`layout()` hides it with the strip).
    func toolbarWidth(shown: CGFloat) -> CGFloat {
        guard let view = toolbar?.view, shown > 0 else { return 0 }
        return min(view.intrinsicContentSize.width, bounds.width / 2)
    }
}
