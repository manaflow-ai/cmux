import AppKit
import CmuxNextDesign
import CmuxNextTabs

// The pane's "…" (`PaneToolbar`) sits at the strip's trailing end, as wide as it needs: in frame
// layout the strip gives up that width (`layout()`); pinned to a browser's band (R109) it pins
// beside it.
extension PaneContentView {
    func installToolbar(replacing old: PaneToolbar?) {
        // Pins to a browser's band name the toolbar: they are made again for the new one.
        let pinned = isBandActive
        if pinned { releaseBand() }
        old?.view.removeFromSuperview()
        if let view = toolbar?.view { addSubview(view, positioned: .above, relativeTo: stripView); view.stripFrame = { [weak self] in self?.stripView.frame } }
        if pinned { updateBand() }
        needsLayout = true
    }

    /// "…"'s width beside a strip `shown` tall (`layout()` hides it with the strip).
    func toolbarWidth(shown: CGFloat) -> CGFloat {
        guard let view = toolbar?.view, shown > 0 else { return 0 }
        return min(view.intrinsicContentSize.width, bounds.width / 2)
    }

    /// "…"'s pins beside a strip pinned to a browser's band.
    func toolbarBandPins() -> [NSLayoutConstraint] {
        guard let view = toolbar?.view else { return [] }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.required, for: .horizontal)
        // Below the window's stay-put priority (500): overflow compresses the toolbar instead
        // of making a narrow window grow to twice the toolbar's intrinsic width.
        view.setContentCompressionResistancePriority(.init(490), for: .horizontal)
        return [
            view.topAnchor.constraint(equalTo: stripView.topAnchor),
            view.heightAnchor.constraint(equalTo: stripView.heightAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.5),
        ]
    }
}

// A pane on a layout spring (a split, a close, a zoom) resizes on every display frame. Its strip is laid out
// once, at the width it rests at, and shown cut to the pane's width meanwhile (`TabStripView.shownWidth`); the
// tab bar's hover area and the strip's hover follow when the spring lands.
extension PaneContentView: PaneMotionSettling {
    /// The strip's frame width for a strip `width` wide now: on a spring that resizes the pane, its width at
    /// rest (`enclosingRestSizeChange`), the same on every frame; otherwise `width`.
    func stripLayoutWidth(shown width: CGFloat) -> CGFloat {
        guard let change = enclosingRestSizeChange else { return width }
        return max(0, width + change.width)
    }

    /// The spring landed: the frame is final, so the strip shows whole again (a landing frame the same size as
    /// the last spring frame lays nothing out by itself), and the bar's hover area and what is under the pointer
    /// are read again.
    func paneMotionDidSettle() {
        needsLayout = true
        toolbar?.view.refreshCorner()
        stripView.paneMovedInWindow()
    }
}
