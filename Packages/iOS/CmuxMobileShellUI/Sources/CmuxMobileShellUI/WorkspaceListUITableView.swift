#if os(iOS)
import UIKit

/// Table view that reports the two layout changes which invalidate exact row heights.
@MainActor
final class WorkspaceListUITableView: UITableView {
    var layoutMetricsDidChange: (() -> Void)?
    var scrollEdgeRegistrationNeedsUpdate: (() -> Void)?

    private var measuredWidth: CGFloat = 0

    override init(frame: CGRect, style: UITableView.Style) {
        super.init(frame: frame, style: style)
        configureTable()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureTable()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        requestScrollEdgeRegistrationUpdate()
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

    private func configureTable() {
        // Row heights are exact values from the coordinator. Hosted content
        // must never resize a row behind its back as previews and timestamps
        // change, and no estimate may stand in for a real height.
        selfSizingInvalidation = .disabled
        estimatedRowHeight = 0
        estimatedSectionHeaderHeight = 0
        estimatedSectionFooterHeight = 0
        contentInsetAdjustmentBehavior = .automatic
        if #available(iOS 26.0, *) {
            topEdgeEffect.style = .soft
            // New Task is an overlay, so the tab bar owns this effect's edge.
            bottomEdgeEffect.style = .soft
        }
    }

    func requestScrollEdgeRegistrationUpdate() {
        scrollEdgeRegistrationNeedsUpdate?()
    }
}
#endif
