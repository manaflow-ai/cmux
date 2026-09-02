import UIKit

/// The accessory button row's horizontal scroll view, with a leading-edge fade
/// that ramps in as the row scrolls.
///
/// The row is clipped on its left by the pinned composer button, so without a
/// mask the Ctrl/Esc/Tab keys shear off abruptly against it mid-scroll. This
/// masks the leading ``fadeWidth`` points with an alpha gradient whose edge
/// opacity tracks ``leadingEdgeAlpha(contentOffsetX:fadeWidth:)``: invisible
/// at rest (the first key renders fully), strengthening with the first points
/// of scroll, and a full transparent→opaque ramp once scrolled past a band
/// width. Buttons therefore dissolve under the composer button instead of
/// hard-clipping, which also signals that scrolled-away keys exist to the
/// left (HIG scroll-view guidance: imply continuation past the edge).
///
/// The mask is updated from `layoutSubviews`, which UIKit invokes for every
/// `contentOffset` change, so no scroll-view delegate is consumed; the
/// gradient's frame tracks `bounds` (whose origin IS the content offset) to
/// stay glued to the visible viewport rather than scrolling with the content.
final class AccessoryEdgeFadeScrollView: UIScrollView {
    /// Width in points of the leading fade band, and the scroll distance over
    /// which the fade ramps from nothing to full strength. Sized near one
    /// button width (`accessoryButtonMinWidth` is 32) so a key dissolves over
    /// roughly its own width as it slides under the row's leading edge.
    nonisolated static let fadeWidth: CGFloat = 24

    /// Opacity at the row's leading edge for a given scroll offset. 1 (no
    /// fade) while the row rests at its origin, ramping linearly to 0 (fully
    /// faded) once the content has scrolled a full ``fadeWidth`` past the
    /// edge. The ramp is what makes the fade INCREMENTAL: a 1pt scroll barely
    /// dims the edge instead of snapping a full gradient on. Negative offsets
    /// stay fully opaque, which covers both rubber-band bounce and the at-rest
    /// position when the host carries the inter-button gap as a leading
    /// content inset (rest offset -gap): the fade begins only once a key
    /// actually reaches the viewport's leading edge.
    nonisolated static func leadingEdgeAlpha(contentOffsetX: CGFloat, fadeWidth: CGFloat = fadeWidth) -> CGFloat {
        guard fadeWidth > 0 else { return 0 }
        return 1 - min(1, max(0, contentOffsetX / fadeWidth))
    }

    /// The fade band's end position as a fraction of the viewport width, for a
    /// gradient whose coordinate space spans the visible bounds. Clamped to 1
    /// so a degenerate (narrower-than-band) viewport fades across its whole
    /// width instead of placing a gradient stop out of range.
    nonisolated static func fadeBandFraction(viewportWidth: CGFloat, fadeWidth: CGFloat = fadeWidth) -> CGFloat {
        guard viewportWidth > 0 else { return 0 }
        return min(1, fadeWidth / viewportWidth)
    }

    private let fadeMask: CAGradientLayer = {
        let gradient = CAGradientLayer()
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        return gradient
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.mask = fadeMask
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateFadeMask()
    }

    private func updateFadeMask() {
        guard bounds.width > 0 else { return }
        let edgeAlpha = Self.leadingEdgeAlpha(contentOffsetX: contentOffset.x)
        let bandEnd = Self.fadeBandFraction(viewportWidth: bounds.width)
        // Mask layers read only the alpha channel; disable implicit animations
        // so the gradient tracks finger-driven scrolling without trailing.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = bounds
        fadeMask.colors = [
            UIColor(white: 0, alpha: edgeAlpha).cgColor,
            UIColor(white: 0, alpha: 1).cgColor,
            UIColor(white: 0, alpha: 1).cgColor,
        ]
        fadeMask.locations = [0, NSNumber(value: Double(bandEnd)), 1]
        CATransaction.commit()
    }
}
