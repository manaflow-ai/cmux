import AppKit
import CmuxNextDesign

/// A view in a frame-laid column (ChromeFrameLayout.swift): measured at the
/// column's inner width, filling that width at a fixed height (a text
/// field), or a row of views (buttons) that stacks when it does not fit.
enum ChromeColumnItem {
    case view(NSView)
    case fill(NSView, height: CGFloat)
    case row([NSView], ChromeRowLayout)

    /// Its alignment size at most `width` wide. A filling item takes no
    /// natural width: it is as wide as what the rest of the column needs.
    @MainActor func size(maxWidth width: CGFloat, natural: Bool) -> CGSize {
        switch self {
        case .view(let view):
            return view.chromeLayoutSize(maxWidth: width)
        case .fill(_, let height):
            return CGSize(width: natural ? 0 : width, height: height)
        case .row(let views, let row):
            let sizes = views.map { $0.chromeLayoutSize(maxWidth: width) }
            return row.size(of: sizes, maxWidth: width)
        }
    }

    /// Places it at `rect`, its alignment rect.
    @MainActor func place(in rect: CGRect) {
        switch self {
        case .view(let view), .fill(let view, _):
            view.setChromeLayoutRect(rect)
        case .row(let views, let row):
            let sizes = views.map { $0.chromeLayoutSize(maxWidth: rect.width) }
            for (view, frame) in zip(views, row.placeFitting(sizes, in: rect)) { view.setChromeLayoutRect(frame) }
        }
    }
}

/// A view that lays its subviews out by frame in `layout()`: a new size asks
/// for a layout, as views::View::OnBoundsChanged does (ui/views/view.cc),
/// whoever set the frame (a parent's frame layout, the overlay host or Auto
/// Layout).
class ChromeFrameView: NSView {
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true } // invalidate: the subviews lay out at the new size (the check above)
    }
}

extension OverlayCardLayout {
    /// The card's size in a room `room` wide: its width from the items'
    /// natural sizes, its height from their sizes at that width.
    @MainActor func measure(_ items: [ChromeColumnItem], room: CGFloat) -> CGSize {
        let natural = items.map { $0.size(maxWidth: maxItemWidth(room: room), natural: true) }
        let cardWidth = self.width(natural: natural, room: room)
        let inner = max(cardWidth - column.insets.horizontal, 0)
        return self.size(width: cardWidth, items: items.map { $0.size(maxWidth: inner, natural: false) })
    }
}

extension ChromeColumnLayout {
    /// Places `items` in `box` (the card's content, its own coordinates),
    /// each measured at the inner width.
    @MainActor func layout(_ items: [ChromeColumnItem], in box: CGRect) {
        let inner = max(box.width - insets.horizontal, 0)
        let sizes = items.map { $0.size(maxWidth: inner, natural: false) }
        for (item, rect) in zip(items, place(sizes, in: box)) { item.place(in: rect) }
    }
}

extension PageMessageLayout {
    /// The load error page's and the sad tab's column: centered over the
    /// page and raised by the toolbar's height, as Chrome's sad tab.
    @MainActor static func statusPage(rightToLeft: Bool) -> PageMessageLayout {
        PageMessageLayout(column: ChromeColumnLayout(spacing: BrowserMetrics.overlayPadding, rightToLeft: rightToLeft),
                          maxWidth: BrowserMetrics.promptMaxWidth, margin: statusPageMargin, lift: BrowserMetrics.toolbarHeight)
    }

    /// The least room between a status page's column and the page's sides.
    static let statusPageMargin: CGFloat = 16

    /// Places the shown `views` in `bounds`, each measured at the item width.
    @MainActor func layout(_ views: [NSView], in bounds: CGRect) {
        let items = views.filter { !$0.isHidden }
        let width = itemWidth(in: bounds)
        let rects = place(items.map { $0.chromeLayoutSize(maxWidth: width) }, in: bounds)
        for (view, rect) in zip(items, rects) { view.setChromeLayoutRect(rect) }
    }
}

extension NSView {
    /// The view's alignment size (what Auto Layout aligns) at most `maxWidth`
    /// wide: a `ChromeLabel` breaks its lines at that width (a one-line label
    /// is cut and truncates); a view with an intrinsic size and no
    /// constraints of its own takes that size, any other its fitting size.
    func chromeLayoutSize(maxWidth: CGFloat) -> CGSize {
        let width = max(maxWidth, 0)
        if let label = self as? ChromeLabel {
            let insets = label.alignmentRectInsets
            let padding = insets.left + insets.right
            let frame = label.size(forWidth: width + padding)
            return CGSize(width: min(frame.width - padding, width), height: frame.height - insets.top - insets.bottom)
        }
        let intrinsic = intrinsicContentSize
        let measured = constraints.isEmpty && intrinsic.width != NSView.noIntrinsicMetric && intrinsic.height != NSView.noIntrinsicMetric
            ? intrinsic : fittingSize
        return CGSize(width: min(measured.width, width), height: measured.height)
    }

    /// Places the view so its alignment rect is `rect`; no frame write when
    /// it is already there.
    func setChromeLayoutRect(_ rect: CGRect) {
        let target = frame(forAlignmentRect: rect)
        if frame != target { frame = target }
    }

    /// Whether the view lays out right to left (its column and row layouts
    /// mirror).
    var laysOutRightToLeft: Bool { userInterfaceLayoutDirection == .rightToLeft }
}
