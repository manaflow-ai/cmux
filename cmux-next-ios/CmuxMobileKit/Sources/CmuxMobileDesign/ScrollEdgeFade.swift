import CoreGraphics

/// A horizontal scroller's edge fade, the terminal key row's (`KeyRowFade`, classic
/// cmux iOS's `AccessoryEdgeFadeScrollView`): content dissolves over `width` points
/// at an edge with more of it past that edge, in proportion to how much is past it.
/// At the row's start the leading edge is crisp; `width` points in, it fades fully.
/// The trailing edge mirrors it, so the last key is whole once the row ends there.
public struct ScrollEdgeFade: Sendable {
    public static let width: CGFloat = 24

    public init() {}

    /// The edge's opacity with `hidden` points of content past it: 1 with none, 0 from `width` on.
    public func edgeAlpha(hidden: CGFloat) -> Double {
        Double(1 - min(1, max(0, hidden / Self.width)))
    }

    /// The left and right edges' opacities for a scroller whose content (`contentWidth`,
    /// insets included) is scrolled `offset` points and shows `visibleWidth` of it.
    public func edgeAlphas(offset: CGFloat, visibleWidth: CGFloat, contentWidth: CGFloat) -> (left: Double, right: Double) {
        (edgeAlpha(hidden: offset), edgeAlpha(hidden: contentWidth - offset - visibleWidth))
    }
}

#if os(iOS)
import UIKit

/// A horizontal UIKit scroll view with `ScrollEdgeFade` at its edges: a gradient
/// mask on its layer, redrawn in `layoutSubviews`, which UIKit runs on every
/// scroll and after every content size change.
@MainActor
public final class ScrollEdgeFadeScrollView: UIScrollView {
    private let gradient = CAGradientLayer()
    /// The left and right edges' opacities as last drawn.
    public private(set) var edges: (left: Double, right: Double) = (1, 1)
    /// Off: no mask, the content is cut at the edges (the DEBUG gallery's "before").
    public var fadesEdges = true {
        didSet { layer.mask = fadesEdges ? gradient : nil; setNeedsLayout() }
    }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        layer.mask = gradient
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    // A content size or inset set from code changes the fade without a layout pass of its own.
    override public var contentSize: CGSize {
        didSet { if oldValue != contentSize { setNeedsLayout() } }
    }

    override public func adjustedContentInsetDidChange() {
        super.adjustedContentInsetDidChange()
        setNeedsLayout()
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        guard fadesEdges else { return }
        let insets = adjustedContentInset
        let size = bounds.size
        let edges = ScrollEdgeFade().edgeAlphas(offset: contentOffset.x + insets.left,
                                                visibleWidth: size.width,
                                                contentWidth: contentSize.width + insets.left + insets.right)
        self.edges = edges
        let ramp = Double(min(0.5, ScrollEdgeFade.width / max(size.width, 1)))
        // The mask tracks scrolling: no implicit animation, or it would trail the content.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The layer's bounds origin is the content offset, so the mask moves with it.
        gradient.frame = CGRect(origin: bounds.origin, size: size)
        gradient.colors = [UIColor(white: 0, alpha: edges.left).cgColor, UIColor.black.cgColor,
                           UIColor.black.cgColor, UIColor(white: 0, alpha: edges.right).cgColor]
        gradient.locations = [0, NSNumber(value: ramp), NSNumber(value: 1 - ramp), 1]
        CATransaction.commit()
    }
}
#endif
