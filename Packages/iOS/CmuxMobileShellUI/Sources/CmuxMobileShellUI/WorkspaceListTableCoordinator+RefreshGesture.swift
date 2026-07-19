#if os(iOS)
import UIKit

/// Scroll delegate entry points for the workspace list refresh gesture.
@MainActor
extension WorkspaceListTableCoordinator {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let tableView = scrollView as? WorkspaceListUITableView,
              tableView === self.tableView,
              refreshBaseline != nil else {
            return
        }
        switch refreshVisualState {
        case .idle:
            layoutRefreshHeader(in: tableView)
            refreshHeaderView?.setPullProgress(
                refreshGeometry(in: tableView).pullProgress
            )
        case .disabled, .settling, .held, .collapsing:
            break
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        finishActiveRefreshAnimation()
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard let tableView = scrollView as? WorkspaceListUITableView,
              tableView === self.tableView,
              refreshVisualState == .idle,
              configuration.refresh != nil else {
            return
        }
        guard refreshGeometry(in: tableView).isArmed else { return }
        _ = beginRefresh(releaseTargetContentOffset: targetContentOffset)
    }

    func scrollViewDidEndDragging(
        _ scrollView: UIScrollView,
        willDecelerate decelerate: Bool
    ) {
        guard let tableView = scrollView as? WorkspaceListUITableView,
              tableView === self.tableView else {
            return
        }
        if case .settling(let refreshID) = refreshVisualState {
            animateRefreshSettle(refreshID, in: tableView)
            return
        }
        if !decelerate {
            tryStartPendingRefreshCollapse()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        tryStartPendingRefreshCollapse()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        tryStartPendingRefreshCollapse()
    }

    func animateRefreshSettle(
        _ refreshID: WorkspaceListRefreshLifecycle.RefreshID,
        to heldOffset: CGPoint? = nil,
        in tableView: WorkspaceListUITableView
    ) {
        guard let baseline = refreshBaseline,
              refreshVisualState == .settling(refreshID),
              refreshVisualAnimator == nil else {
            return
        }
        let heldOffset = heldOffset ?? CGPoint(
            x: tableView.contentOffset.x,
            y: refreshGeometry(in: tableView).heldOffsetY
        )
        let applyHeldGeometry = { [weak self, weak tableView] in
            guard let self, let tableView else { return }
            self.applyRefreshHeldGeometry(
                baseline: baseline,
                heldOffset: heldOffset,
                in: tableView
            )
        }

        guard !UIAccessibility.isReduceMotionEnabled else {
            UIView.performWithoutAnimation(applyHeldGeometry)
            tableView.bounces = baseline.bounces
            refreshVisualState = .held(refreshID)
            tryStartPendingRefreshCollapse()
            return
        }

        refreshVisualAnimationGeneration &+= 1
        let animationGeneration = refreshVisualAnimationGeneration
        let animator = UIViewPropertyAnimator(
            duration: 0.30,
            curve: .easeInOut,
            animations: applyHeldGeometry
        )
        refreshVisualAnimator = animator
        animator.addCompletion { [weak self, weak tableView] _ in
            guard let self,
                  self.refreshVisualAnimationGeneration == animationGeneration,
                  let tableView,
                  tableView === self.tableView else {
                return
            }
            self.refreshVisualAnimator = nil
            UIView.performWithoutAnimation(applyHeldGeometry)
            tableView.bounces = baseline.bounces
            guard self.refreshVisualState == .settling(refreshID) else { return }
            self.refreshVisualState = .held(refreshID)
            self.tryStartPendingRefreshCollapse()
        }
        animator.startAnimation()
    }

    private func applyRefreshHeldGeometry(
        baseline: RefreshBaseline,
        heldOffset: CGPoint,
        in tableView: WorkspaceListUITableView
    ) {
        mutateRefreshInsets {
            var contentInset = baseline.contentInset
            contentInset.top += WorkspaceListRefreshGeometry.holdHeight
            tableView.contentInset = contentInset
            var indicatorInsets = baseline.verticalScrollIndicatorInsets
            indicatorInsets.top += WorkspaceListRefreshGeometry.holdHeight
            tableView.verticalScrollIndicatorInsets = indicatorInsets
            tableView.contentOffset = heldOffset
        }
        tableView.layoutIfNeeded()
    }

    func installRefreshPinnedInsets(
        baseline: RefreshBaseline,
        extraTop: CGFloat,
        releasedContentOffset: CGPoint,
        in tableView: WorkspaceListUITableView
    ) {
        mutateRefreshInsets {
            UIView.performWithoutAnimation {
                var contentInset = baseline.contentInset
                contentInset.top += extraTop
                tableView.contentInset = contentInset
                var indicatorInsets = baseline.verticalScrollIndicatorInsets
                indicatorInsets.top += extraTop
                tableView.verticalScrollIndicatorInsets = indicatorInsets
                tableView.setContentOffset(releasedContentOffset, animated: false)
            }
        }
    }

    func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
        guard let tableView = scrollView as? WorkspaceListUITableView,
              tableView === self.tableView,
              refreshBaseline != nil,
              !isMutatingRefreshInsets else {
            return
        }
        if case .collapsing = refreshVisualState {
            return
        }

        let geometry = refreshGeometry(in: tableView)
        let newBaseAdjustedTop = geometry.baseAdjustedTop
        defer { lastBaseAdjustedTop = newBaseAdjustedTop }
        guard let oldBaseAdjustedTop = lastBaseAdjustedTop,
              abs(oldBaseAdjustedTop - newBaseAdjustedTop) > 0.5 else {
            return
        }

        let oldPinnedOffsetY: CGFloat
        let newPinnedOffsetY: CGFloat
        switch refreshVisualState {
        case .settling, .held:
            oldPinnedOffsetY = -(oldBaseAdjustedTop + WorkspaceListRefreshGeometry.holdHeight)
            newPinnedOffsetY = geometry.heldOffsetY
        case .idle:
            oldPinnedOffsetY = -oldBaseAdjustedTop
            newPinnedOffsetY = geometry.restingOffsetY
        case .disabled, .collapsing:
            return
        }
        guard abs(tableView.contentOffset.y - oldPinnedOffsetY) <= 1 else { return }
        tableView.setContentOffset(
            CGPoint(x: tableView.contentOffset.x, y: newPinnedOffsetY),
            animated: false
        )
    }
}
#endif
