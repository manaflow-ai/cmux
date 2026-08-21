public import Bonsplit
import CoreGraphics

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
        guard let adjustment = node.resizeDividerAdjustment(
            targetPaneId: targetPaneId,
            direction: direction,
            amountPixels: amountPixels
        ) else {
            return false
        }
        return controller.setDividerPosition(adjustment.position, forSplit: adjustment.splitId, fromExternal: true)
    }

    /// Grows the focused branch on the nearest split matching `axis`.
    ///
    /// - Parameter node: The current external split-tree snapshot.
    /// - Parameter targetPaneId: The identifier of the focused pane.
    /// - Parameter axis: The split axis whose focused branch should grow.
    /// - Parameter amountPixels: The positive number of pixels requested.
    /// - Parameter controller: The live controller that owns the split tree.
    /// - Returns: Whether a matching divider was found and updated.
    @discardableResult
    public func growPane(
        in node: ExternalTreeNode,
        targetPaneId: String,
        axis: PaneAxis,
        amountPixels: UInt16,
        controller: BonsplitController
    ) -> Bool {
        guard amountPixels > 0,
              let adjustment = node.growFocusedBranchAdjustment(
                targetPaneId: targetPaneId,
                axis: axis,
                amountPixels: amountPixels
              ) else {
            return false
        }
        return controller.setDividerPosition(
            adjustment.position,
            forSplit: adjustment.splitId,
            fromExternal: true
        )
    }
}
