import AppKit

// The pane's "…" (`PaneToolbar`) sits at the strip's trailing end, as wide as it needs: in frame
// layout the strip gives up that width (`layout()`); pinned to a browser's band (R109) it pins
// beside it.
extension PaneContentView {
    func installToolbar(replacing old: PaneToolbar?) {
        // Pins to a browser's band name the toolbar: they are made again for the new one.
        let pinned = isBandActive
        if pinned { releaseBand() }
        old?.view.removeFromSuperview()
        if let view = toolbar?.view { addSubview(view, positioned: .above, relativeTo: stripView); view.strip = stripView }
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
