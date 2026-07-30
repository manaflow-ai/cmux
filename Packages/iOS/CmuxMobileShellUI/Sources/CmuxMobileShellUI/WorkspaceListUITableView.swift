#if os(iOS)
import UIKit

/// Table view that reports the two layout changes which invalidate exact row heights.
@MainActor
final class WorkspaceListUITableView: UITableView {
    var layoutMetricsDidChange: (() -> Void)?

    private var measuredWidth: CGFloat = 0
    private let scrollEdgeCoordinator = WorkspaceListScrollEdgeCoordinator()

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
        if window == nil {
            scrollEdgeCoordinator.unregister()
        } else {
            scrollEdgeCoordinator.registerIfNeeded(for: self)
        }
    }

    override func layoutSubviews() {
        let previousWidth = measuredWidth
        super.layoutSubviews()
        measuredWidth = bounds.width
        if previousWidth > 0, abs(previousWidth - measuredWidth) > 0.5 {
            layoutMetricsDidChange?()
        }
        if window != nil {
            scrollEdgeCoordinator.registerIfNeeded(for: self)
            updateScrollContentInsets()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory
            != traitCollection.preferredContentSizeCategory {
            layoutMetricsDidChange?()
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        scrollEdgeCoordinator.registerIfNeeded(for: self)
        updateScrollContentInsets()
    }

    private func configureScrollEdgeEffects() {
        contentInsetAdjustmentBehavior = .never
        if #available(iOS 26.0, *) {
            topEdgeEffect.style = .soft
            // The hard native effect stays at the tab-bar boundary. Soft and
            // automatic effects fade upward through the floating buttons.
            bottomEdgeEffect.style = .hard
        }
    }

    private func updateScrollContentInsets() {
        let insets = scrollEdgeCoordinator.contentInsets(for: self)
        let previousInsets = contentInset
        guard previousInsets != insets else { return }
        let previousOffset = contentOffset
        let previousMaximumOffsetY = max(
            -previousInsets.top,
            contentSize.height + previousInsets.bottom - bounds.height
        )
        let wasAtBottom = abs(previousOffset.y - previousMaximumOffsetY) <= 1
        contentInset = insets
        scrollIndicatorInsets = insets
        var anchoredOffset = previousOffset
        anchoredOffset.y -= insets.top - previousInsets.top
        if wasAtBottom {
            anchoredOffset.y = max(
                -insets.top,
                contentSize.height + insets.bottom - bounds.height
            )
        }
        setContentOffset(anchoredOffset, animated: false)
    }
}
#endif
