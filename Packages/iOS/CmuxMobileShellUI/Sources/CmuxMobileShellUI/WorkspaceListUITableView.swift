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
        configureScrollEdgeEffects()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureScrollEdgeEffects()
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

    private func configureScrollEdgeEffects() {
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (tableView: WorkspaceListUITableView, _: UITraitCollection) in
            tableView.layoutMetricsDidChange?()
        }
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
