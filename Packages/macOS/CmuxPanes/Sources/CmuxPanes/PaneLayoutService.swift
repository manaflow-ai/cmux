public import Bonsplit
public import CoreGraphics

/// Applies pure split-geometry plans (see `ExternalTreeNode` extensions in
/// `Geometry/`) to a live `BonsplitController`, preserving the legacy
/// divider-mutation order exactly: equalize applies children before their
/// parent, and a resize issues a single divider move.
///
/// `@MainActor` because `BonsplitController` is MainActor-isolated; the
/// service holds no state and is owned as a plain value by its callers.
@MainActor
public struct PaneLayoutService {
    /// Creates the stateless service.
    public init() {}

    /// Equalizes every split matching `orientationFilter` (all splits when
    /// `nil`) in the snapshot, applying the planned divider positions to
    /// `controller`. Lifted from the app-side `SplitEqualizer.equalize`.
    @discardableResult
    public func equalizeSplits(
        in node: ExternalTreeNode,
        controller: BonsplitController,
        orientationFilter: String? = nil
    ) -> SplitEqualizeResult {
        let plan = node.equalizeDividerPlan(orientationFilter: orientationFilter)
        var allSucceeded = !plan.hadInvalidSplitIds
        for adjustment in plan.adjustments {
            if !controller.setDividerPosition(adjustment.position, forSplit: adjustment.splitId, fromExternal: true) {
                allSucceeded = false
            }
        }
        return SplitEqualizeResult(foundSplit: plan.foundSplit, allSucceeded: allSucceeded)
    }

    /// Resizes the pane's controlling divider by `amountPixels` in
    /// `direction`, applying the planned clamped position to `controller`.
    /// Returns whether a divider was found and the move was accepted.
    /// Lifted from the divider math of the app-side `TabManager.resizeSplit`.
    public func resizeSplit(
        in node: ExternalTreeNode,
        targetPaneId: String,
        direction: ResizeDirection,
        amountPixels: UInt16,
        controller: BonsplitController
    ) -> Bool {
        resizeSplitResult(
            in: node,
            targetPaneId: targetPaneId,
            direction: direction,
            amountPixels: amountPixels,
            controller: controller
        ).didApply
    }

    /// Applies a resize and reports the focused branch's resulting share.
    public func resizeSplitResult(
        in node: ExternalTreeNode,
        targetPaneId: String,
        direction: ResizeDirection,
        amountPixels: UInt16,
        controller: BonsplitController
    ) -> PaneResizeResult {
        let plan = node.resizeDividerPlan(
            targetPaneId: targetPaneId,
            direction: direction,
            amountPixels: amountPixels
        )
        let adjustment: SplitDividerAdjustment
        switch plan {
        case .adjustment(let plannedAdjustment):
            adjustment = plannedAdjustment
        case .noMatchingSplit:
            return .noMatchingSplit
        case .invalidSplitIdentifier:
            return .rejected(reason: "The matching split has an invalid identifier.")
        }
        return apply(adjustment, controller: controller)
    }

    /// Sets the focused branch to `share` of the nearest matching split.
    ///
    /// Reapplying the branch's current share succeeds without mutating the
    /// controller, which keeps exact-share shortcuts idempotent.
    ///
    /// - Parameter node: The current external split-tree snapshot.
    /// - Parameter targetPaneId: The identifier of the focused pane.
    /// - Parameter axis: The split axis whose focused branch should change.
    /// - Parameter share: The requested focused-branch share between zero and one.
    /// - Parameter controller: The live controller that owns the split tree.
    /// - Returns: The applied share, a clamped share, or a rejection reason.
    public func setSplitShareResult(
        in node: ExternalTreeNode,
        targetPaneId: String,
        axis: PaneAxis,
        share: CGFloat,
        controller: BonsplitController
    ) -> PaneResizeResult {
        guard share.isFinite, share > 0, share < 1 else {
            return .rejected(reason: "Pane share must be a finite value between zero and one.")
        }
        let plan = node.focusedBranchShareDividerPlan(
            targetPaneId: targetPaneId,
            axis: axis,
            share: share
        )
        switch plan {
        case .adjustment(let adjustment):
            return apply(adjustment, controller: controller, unchangedResultIsSuccess: true)
        case .noMatchingSplit:
            return .noMatchingSplit
        case .invalidSplitIdentifier:
            return .rejected(reason: "The matching split has an invalid identifier.")
        }
    }

    private func apply(
        _ adjustment: SplitDividerAdjustment,
        controller: BonsplitController,
        unchangedResultIsSuccess: Bool = false
    ) -> PaneResizeResult {
        guard let requestedShare = adjustment.requestedFocusedBranchShare,
              let plannedShare = adjustment.focusedBranchShare,
              let initialShare = adjustment.initialFocusedBranchShare,
              let focusedBranchIsFirst = adjustment.focusedBranchIsFirst else {
            return .rejected(reason: "The resize plan did not include focused-branch geometry.")
        }
        let tolerance: CGFloat = 0.000_1
        if abs(plannedShare - initialShare) <= tolerance, unchangedResultIsSuccess {
            return .applied(actualShare: plannedShare)
        }
        guard abs(plannedShare - initialShare) > tolerance else {
            return .rejected(reason: "The pane is already at its resize limit.")
        }
        guard controller.setDividerPosition(
            adjustment.position,
            forSplit: adjustment.splitId,
            fromExternal: true
        ) else {
            return .rejected(reason: "Unable to update the matching split divider.")
        }
        guard let appliedPosition = controller.treeSnapshot().dividerPosition(forSplitId: adjustment.splitId) else {
            return .rejected(reason: "The updated split divider could not be observed.")
        }
        let actualShare = focusedBranchIsFirst ? appliedPosition : 1 - appliedPosition
        if abs(requestedShare - actualShare) > tolerance {
            return .clamped(
                requestedShare: requestedShare,
                actualShare: actualShare
            )
        }
        return .applied(actualShare: actualShare)
    }
}
