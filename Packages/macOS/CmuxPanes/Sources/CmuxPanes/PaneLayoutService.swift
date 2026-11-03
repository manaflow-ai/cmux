public import Bonsplit
import CoreGraphics
public import Foundation

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
        apply(node.equalizeDividerPlan(orientationFilter: orientationFilter), to: controller)
    }

    /// Equalizes only the run of same-orientation splits that directly
    /// contains `paneId` (see
    /// ``ExternalTreeNode/equalizeDividerPlan(forSplitRunContainingPaneId:)``),
    /// so a new split rebalances its own row or column without resetting
    /// dividers elsewhere in the tree.
    @discardableResult
    public func equalizeSplitRun(
        containingPaneId paneId: String,
        in node: ExternalTreeNode,
        controller: BonsplitController
    ) -> SplitEqualizeResult {
        apply(node.equalizeDividerPlan(forSplitRunContainingPaneId: paneId), to: controller)
    }

    /// Equalizes the same-axis row or column containing the identified divider.
    ///
    /// - Parameters:
    ///   - splitId: The clicked split UUID, independent of pane focus.
    ///   - node: The current tree snapshot.
    ///   - controller: The controller that owns the snapshot and divider.
    /// - Returns: Whether a run was found and all divider mutations succeeded.
    @discardableResult
    public func equalizeSplitRun(
        containingSplitId splitId: UUID,
        in node: ExternalTreeNode,
        controller: BonsplitController
    ) -> SplitEqualizeResult {
        apply(node.equalizeDividerPlan(forSplitRunContainingSplitId: splitId), to: controller)
    }

    private func apply(_ plan: SplitEqualizePlan, to controller: BonsplitController) -> SplitEqualizeResult {
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
        guard let adjustment = node.resizeDividerAdjustment(
            targetPaneId: targetPaneId,
            direction: direction,
            amountPixels: amountPixels
        ) else {
            return false
        }
        return controller.setDividerPosition(adjustment.position, forSplit: adjustment.splitId, fromExternal: true)
    }
}
