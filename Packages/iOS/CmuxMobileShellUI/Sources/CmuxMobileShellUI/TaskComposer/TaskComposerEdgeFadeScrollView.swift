#if os(iOS)
import UIKit

/// A horizontal task-composer scroll view whose content dissolves from the
/// adjacent fixed controls into its bounded viewport. The mask follows
/// finger-driven content offsets from `layoutSubviews`, the same UIKit-owned
/// approach used by the terminal accessory bar.
final class TaskComposerEdgeFadeScrollView: UIScrollView {
    nonisolated static let fadeWidth: CGFloat = 24

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

    nonisolated static func edgeAlpha(distance: CGFloat, fadeWidth: CGFloat = fadeWidth) -> CGFloat {
        guard fadeWidth > 0 else { return 1 }
        return 1 - min(1, max(0, distance / fadeWidth))
    }

    private func updateFadeMask() {
        guard bounds.width > 0 else { return }

        let scrollableWidth = contentSize.width - bounds.width + contentInset.left + contentInset.right
        let isScrollable = scrollableWidth > 0.5
        let leadingDistance = max(0, contentOffset.x + contentInset.left)
        let maxContentOffsetX = contentSize.width - bounds.width + contentInset.right
        let trailingDistance = max(0, maxContentOffsetX - contentOffset.x)
        let leadingAlpha = isScrollable ? Self.edgeAlpha(distance: leadingDistance) : 1
        let trailingAlpha = isScrollable ? Self.edgeAlpha(distance: trailingDistance) : 1
        let bandFraction = min(0.5, Self.fadeWidth / bounds.width)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = bounds
        fadeMask.colors = [
            UIColor(white: 0, alpha: leadingAlpha).cgColor,
            UIColor(white: 0, alpha: 1).cgColor,
            UIColor(white: 0, alpha: 1).cgColor,
            UIColor(white: 0, alpha: trailingAlpha).cgColor,
        ]
        fadeMask.locations = [
            0,
            NSNumber(value: Double(bandFraction)),
            NSNumber(value: Double(1 - bandFraction)),
            1,
        ]
        CATransaction.commit()
    }
}
#endif
