public import AppKit

// The omnibar's frame layout (`AddressBarLayout`, Chrome's
// `LocationBarView::Layout`): the chip, the field and the trailing badges on
// the bar's center line, mirrored in a right-to-left layout.
extension AddressBarView {
    /// The bar's height (the toolbar row frames the bar at it).
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: barHeight) }

    public override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    /// The bar's frames for its size and badges now.
    var barLayout: AddressBarLayout {
        let showsBadges = badges.arrangedSubviews.contains { !$0.isHidden }
        let chipWidth = max(chipSide, chip.intrinsicContentSize.width)
        return AddressBarLayout(AddressBarLayout.Input(
            size: bounds.size, chipSize: CGSize(width: chipWidth, height: chipSide), fieldHeight: field.intrinsicContentSize.height,
            badgesSize: showsBadges ? badges.fittingSize : .zero, chipLeading: OmnibarStyle.chipLeading,
            textLeading: OmnibarStyle.textLeading, trailingPadding: OmnibarStyle.trailingPadding,
            badgesTrailing: OmnibarStyle.chipLeading + 2, cardTopOutset: OmnibarStyle.cardTopOutset,
            cardSideOutset: OmnibarStyle.cardSideOutset
        ))
    }

    func applyBarLayout() {
        let bar = barLayout, mapping = chromeFrameMapping
        pill.setChromeFrame(mapping.map(bar.pill))
        backdrop.setChromeFrame(mapping.map(bar.backdrop))
        chip.setChromeFrame(mapping.map(bar.chip))
        field.setChromeFrame(mapping.map(bar.field))
        badges.setChromeFrame(mapping.map(bar.badges))
    }
}
