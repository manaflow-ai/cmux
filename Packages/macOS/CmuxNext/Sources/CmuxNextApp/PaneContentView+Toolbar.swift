import AppKit

// The pane's buttons (`PaneToolbar`, cx-kk7lm) sit at the strip's trailing end, as wide as they
// need: in frame layout the strip gives up that width (`layout()`); pinned to a browser's band
// (R109) they pin beside it.
extension PaneContentView {
    func installToolbar(replacing old: PaneToolbar?) {
        old?.view.removeFromSuperview()
        if let view = toolbar?.view { addSubview(view, positioned: .above, relativeTo: stripView) }
        needsLayout = true
    }

    /// The buttons' width beside a strip `shown` tall: none while the strip is hidden.
    func toolbarWidth(shown: CGFloat) -> CGFloat {
        guard let view = toolbar?.view else { return 0 }
        view.isHidden = shown <= 0
        return view.isHidden ? 0 : min(view.intrinsicContentSize.width, bounds.width / 2)
    }

    /// The buttons' pins beside a strip pinned to a browser's band.
    func toolbarBandPins() -> [NSLayoutConstraint] {
        guard let view = toolbar?.view else { return [] }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.required, for: .horizontal)
        return [
            view.topAnchor.constraint(equalTo: stripView.topAnchor),
            view.heightAnchor.constraint(equalTo: stripView.heightAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ]
    }
}
