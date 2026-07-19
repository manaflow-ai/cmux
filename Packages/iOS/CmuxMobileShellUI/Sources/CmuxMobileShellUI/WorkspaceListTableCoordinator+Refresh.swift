#if os(iOS)
import UIKit

/// Pull gesture, spinner, inset, and collapse ownership for the workspace list.
@MainActor
extension WorkspaceListTableCoordinator {

    /// Starts the custom refresh presentation after the pull gesture crosses
    /// the threshold. Internal visibility keeps the lifecycle directly
    /// testable without synthesizing a private UIKit control event.
    @discardableResult
    func beginRefresh(
        releaseTargetContentOffset: UnsafeMutablePointer<CGPoint>? = nil
    ) -> Bool {
        guard let refresh = configuration.refresh,
              let tableView,
              refreshBaseline != nil,
              refreshVisualState == .idle,
              let refreshID = refreshLifecycle.begin(
                  currentGeneration: configuration.refreshCompletionGeneration
              ) else {
            return false
        }

        let refreshDidComplete = configuration.refreshDidComplete
        beginRefreshPresentation(
            refreshID,
            releaseTargetContentOffset: releaseTargetContentOffset,
            in: tableView
        )
        refreshTaskID = refreshID
        refreshTask = Task { @MainActor [weak self, weak tableView] in
            await refresh()
            guard let self else { return }
            self.clearRefreshTask(refreshID)
            guard !Task.isCancelled else {
                self.cancelRefresh(refreshID)
                return
            }
            guard let tableView,
                  tableView === self.tableView,
                  self.ownsRefreshPresentation(refreshID) else {
                self.cancelRefresh(refreshID)
                return
            }
            guard self.refreshLifecycle.refreshActionCompleted(refreshID) else {
                return
            }
            refreshDidComplete()
        }
        return true
    }

    func updateRefreshPresentation(in tableView: UITableView) {
        guard let tableView = tableView as? WorkspaceListUITableView else { return }
        if configuration.refresh != nil {
            installRefreshPresentationIfNeeded(in: tableView)
        } else if refreshBaseline != nil {
            uninstallRefreshPresentation(from: tableView)
        }
    }

    private func installRefreshPresentationIfNeeded(
        in tableView: WorkspaceListUITableView
    ) {
        guard refreshBaseline == nil else {
            layoutRefreshHeader(in: tableView)
            return
        }

        // A UIRefreshControl owns inset changes asynchronously. The custom
        // presentation below is the sole refresh geometry owner.
        tableView.refreshControl = nil
        refreshBaseline = RefreshBaseline(
            contentInset: tableView.contentInset,
            verticalScrollIndicatorInsets: tableView.verticalScrollIndicatorInsets,
            alwaysBounceVertical: tableView.alwaysBounceVertical,
            bounces: tableView.bounces
        )
        let headerView = WorkspaceListRefreshHeaderView()
        refreshHeaderView = headerView
        tableView.addSubview(headerView)
        tableView.alwaysBounceVertical = true
        refreshVisualState = .idle
        layoutRefreshHeader(in: tableView)
        lastBaseAdjustedTop = refreshGeometry(in: tableView).baseAdjustedTop
    }

    func uninstallRefreshPresentation(
        from tableView: WorkspaceListUITableView
    ) {
        cancelRefreshVisualAnimation()
        cancelRefreshTask()
        refreshLifecycle.reset()
        pendingCollapseID = nil

        if let baseline = refreshBaseline {
            let geometry = refreshGeometry(in: tableView)
            let restoredOffsetY = max(
                tableView.contentOffset.y,
                geometry.restingOffsetY
            )
            mutateRefreshInsets {
                UIView.performWithoutAnimation {
                    tableView.contentInset = baseline.contentInset
                    tableView.verticalScrollIndicatorInsets =
                        baseline.verticalScrollIndicatorInsets
                    tableView.alwaysBounceVertical = baseline.alwaysBounceVertical
                    tableView.bounces = baseline.bounces
                    tableView.setContentOffset(
                        CGPoint(x: tableView.contentOffset.x, y: restoredOffsetY),
                        animated: false
                    )
                    tableView.layoutIfNeeded()
                }
            }
        }

        refreshHeaderView?.endRefreshing()
        refreshHeaderView?.removeFromSuperview()
        refreshHeaderView = nil
        refreshBaseline = nil
        lastBaseAdjustedTop = nil
        refreshVisualState = .disabled
    }

    func layoutRefreshHeader(in tableView: WorkspaceListUITableView) {
        refreshHeaderView?.frame = CGRect(
            x: 0,
            y: -WorkspaceListRefreshGeometry.holdHeight,
            width: tableView.bounds.width,
            height: WorkspaceListRefreshGeometry.holdHeight
        )
        if let refreshHeaderView {
            tableView.bringSubviewToFront(refreshHeaderView)
        }
    }

    func refreshGeometry(
        in tableView: WorkspaceListUITableView
    ) -> WorkspaceListRefreshGeometry {
        let baselineInset = refreshBaseline?.contentInset ?? tableView.contentInset
        return WorkspaceListRefreshGeometry(
            baseContentInset: baselineInset,
            adjustedContentInset: tableView.adjustedContentInset,
            currentContentInset: tableView.contentInset,
            contentOffset: tableView.contentOffset
        )
    }

    private func beginRefreshPresentation(
        _ refreshID: WorkspaceListRefreshLifecycle.RefreshID,
        releaseTargetContentOffset: UnsafeMutablePointer<CGPoint>?,
        in tableView: WorkspaceListUITableView
    ) {
        guard let baseline = refreshBaseline else { return }
        cancelRefreshVisualAnimation()
        layoutRefreshHeader(in: tableView)
        refreshHeaderView?.beginRefreshing()

        let releasedContentOffset = tableView.contentOffset
        let releasePinHeight = refreshGeometry(in: tableView).releasePinHeight
        installRefreshPinnedInsets(
            baseline: baseline,
            extraTop: releasePinHeight,
            releasedContentOffset: releasedContentOffset,
            in: tableView
        )

        let heldOffset = CGPoint(
            x: releasedContentOffset.x,
            y: refreshGeometry(in: tableView).heldOffsetY
        )
        lastBaseAdjustedTop = refreshGeometry(in: tableView).baseAdjustedTop
        refreshVisualState = .settling(refreshID)
        if let releaseTargetContentOffset {
            // Pin the exact release position as a legal edge, then remove the
            // gesture's velocity. The settle animator is the sole motion owner.
            tableView.bounces = false
            releaseTargetContentOffset.pointee = releasedContentOffset
            return
        }

        animateRefreshSettle(refreshID, to: heldOffset, in: tableView)
    }

    private func clearRefreshTask(_ refreshID: WorkspaceListRefreshLifecycle.RefreshID) {
        guard refreshTaskID == refreshID else { return }
        refreshTask = nil
        refreshTaskID = nil
    }

    private func cancelRefreshTask() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskID = nil
    }

    private func cancelRefresh(
        _ refreshID: WorkspaceListRefreshLifecycle.RefreshID
    ) {
        guard refreshLifecycle.cancelRefresh(refreshID) else { return }
        restoreInstalledRefreshPresentation()
    }

    func refreshSnapshotApplyCompleted(
        _ applyID: WorkspaceListRefreshLifecycle.SnapshotApplyID
    ) {
        guard let collapseID = refreshLifecycle.snapshotApplyCompleted(applyID) else { return }
        scheduleRefreshCollapse { [weak self] in
            guard let self else { return }
            guard let tableView = self.tableView,
                  self.containerView?.tableView === tableView,
                  self.refreshBaseline != nil,
                  self.refreshHeaderView?.superview === tableView else {
                self.cancelRefreshCollapse(collapseID)
                return
            }
            self.pendingCollapseID = collapseID
            self.tryStartPendingRefreshCollapse()
        }
    }

    private func cancelRefreshCollapse(
        _ collapseID: WorkspaceListRefreshLifecycle.CollapseID
    ) {
        guard refreshLifecycle.cancelCollapse(collapseID) else { return }
        pendingCollapseID = nil
        restoreInstalledRefreshPresentation()
    }

    func tryStartPendingRefreshCollapse() {
        guard let collapseID = pendingCollapseID,
              let tableView,
              refreshBaseline != nil,
              !tableView.isTracking,
              !tableView.isDragging,
              !tableView.isDecelerating else {
            return
        }
        guard case .held = refreshVisualState else { return }
        guard refreshLifecycle.collapseStarted(collapseID) else {
            pendingCollapseID = nil
            return
        }
        pendingCollapseID = nil
        refreshVisualState = .collapsing(collapseID)
        let completion: RefreshCollapseAction = { [weak self] in
            guard let self,
                  self.refreshLifecycle.collapseCompleted(collapseID) else {
                return
            }
            self.refreshVisualState = self.refreshBaseline == nil ? .disabled : .idle
            self.refreshHeaderView?.endRefreshing()
        }
        if let injectedRefreshCollapseAnimation {
            injectedRefreshCollapseAnimation(tableView, completion)
        } else {
            animateRefreshCollapse(in: tableView, completion: completion)
        }
    }

    private func animateRefreshCollapse(
        in tableView: WorkspaceListUITableView,
        completion: @escaping RefreshCollapseAction
    ) {
        guard let baseline = refreshBaseline else {
            completion()
            return
        }
        cancelRefreshVisualAnimation()
        let targetOffset = CGPoint(
            x: tableView.contentOffset.x,
            y: refreshGeometry(in: tableView).collapseTargetOffsetY
        )
        let applyFinalGeometry = { [weak self, weak tableView] in
            guard let self, let tableView else { return }
            self.mutateRefreshInsets {
                tableView.contentInset = baseline.contentInset
                tableView.verticalScrollIndicatorInsets =
                    baseline.verticalScrollIndicatorInsets
                tableView.contentOffset = targetOffset
            }
            self.refreshHeaderView?.alpha = 0
            tableView.layoutIfNeeded()
        }

        guard !UIAccessibility.isReduceMotionEnabled else {
            UIView.performWithoutAnimation(applyFinalGeometry)
            completion()
            return
        }

        refreshVisualAnimationGeneration &+= 1
        let animationGeneration = refreshVisualAnimationGeneration
        let animator = UIViewPropertyAnimator(duration: 0.25, curve: .easeOut) {
            applyFinalGeometry()
        }
        refreshVisualAnimator = animator
        animator.addCompletion { [weak self, weak tableView] _ in
            guard let self,
                  self.refreshVisualAnimationGeneration == animationGeneration,
                  let tableView,
                  tableView === self.tableView else {
                return
            }
            self.refreshVisualAnimator = nil
            UIView.performWithoutAnimation(applyFinalGeometry)
            completion()
        }
        animator.startAnimation()
    }

    private func ownsRefreshPresentation(
        _ refreshID: WorkspaceListRefreshLifecycle.RefreshID
    ) -> Bool {
        switch refreshVisualState {
        case .settling(let activeID), .held(let activeID):
            return activeID == refreshID
        case .disabled, .idle, .collapsing:
            return false
        }
    }

    private func restoreInstalledRefreshPresentation() {
        guard let tableView,
              let baseline = refreshBaseline else {
            refreshVisualState = .disabled
            return
        }
        cancelRefreshVisualAnimation()
        let targetOffset = CGPoint(
            x: tableView.contentOffset.x,
            y: refreshGeometry(in: tableView).collapseTargetOffsetY
        )
        mutateRefreshInsets {
            UIView.performWithoutAnimation {
                tableView.contentInset = baseline.contentInset
                tableView.verticalScrollIndicatorInsets =
                    baseline.verticalScrollIndicatorInsets
                tableView.bounces = baseline.bounces
                tableView.setContentOffset(targetOffset, animated: false)
                tableView.layoutIfNeeded()
            }
        }
        refreshHeaderView?.endRefreshing()
        refreshVisualState = .idle
        pendingCollapseID = nil
        lastBaseAdjustedTop = refreshGeometry(in: tableView).baseAdjustedTop
    }

    func finishActiveRefreshAnimation() {
        guard let refreshVisualAnimator else { return }
        refreshVisualAnimator.stopAnimation(false)
        refreshVisualAnimator.finishAnimation(at: .end)
    }

    private func cancelRefreshVisualAnimation() {
        refreshVisualAnimationGeneration &+= 1
        refreshVisualAnimator?.stopAnimation(true)
        refreshVisualAnimator = nil
    }

    func mutateRefreshInsets(_ mutation: () -> Void) {
        isMutatingRefreshInsets = true
        mutation()
        isMutatingRefreshInsets = false
    }
}
#endif
