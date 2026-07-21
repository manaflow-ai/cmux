#if os(iOS)
import UIKit

/// Table view that reports the two layout changes which invalidate exact row heights.
@MainActor
final class WorkspaceListUITableView: UITableView {
    var layoutMetricsDidChange: (() -> Void)?

    private var measuredWidth: CGFloat = 0

    override init(frame: CGRect, style: UITableView.Style) {
        super.init(frame: frame, style: style)
        configureTopScrollEdgeEffect()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureTopScrollEdgeEffect()
    }

    override func layoutSubviews() {
        let previousWidth = measuredWidth
        super.layoutSubviews()
        measuredWidth = bounds.width
        if previousWidth > 0, abs(previousWidth - measuredWidth) > 0.5 {
            layoutMetricsDidChange?()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory
            != traitCollection.preferredContentSizeCategory {
            layoutMetricsDidChange?()
        }
    }

    private func configureTopScrollEdgeEffect() {
        if #available(iOS 26.0, *) {
            topEdgeEffect.style = .soft
        }
    }
}
#endif
