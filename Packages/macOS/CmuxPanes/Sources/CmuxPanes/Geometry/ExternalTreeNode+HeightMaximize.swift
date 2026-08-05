public import Bonsplit
public import CoreGraphics
import Foundation

extension ExternalTreeNode {
    /// Plans a height-only maximize that preserves horizontal split geometry.
    public func heightMaximizePlan(
        targetPaneId: String,
        collapsedPaneHeight: CGFloat,
        dividerThickness: CGFloat
    ) -> PaneHeightMaximizePlanResult {
        guard collapsedPaneHeight.isFinite, collapsedPaneHeight > 0,
              dividerThickness.isFinite, dividerThickness >= 0,
              containsPane(id: targetPaneId) else {
            return .noMatchingSplit
        }

        var adjustments: [PaneHeightMaximizePlan.Adjustment] = []
        let result = appendHeightMaximizeAdjustments(
            targetPaneId: targetPaneId,
            bounds: pixelBounds(),
            collapsedPaneHeight: collapsedPaneHeight,
            dividerThickness: dividerThickness,
            adjustments: &adjustments
        )
        switch result {
        case .found:
            return adjustments.isEmpty
                ? .noMatchingSplit
                : .plan(PaneHeightMaximizePlan(adjustments: adjustments))
        case .invalidSplitIdentifier:
            return .invalidSplitIdentifier
        case .insufficientHeight:
            return .insufficientHeight
        }
    }

    private enum HeightMaximizeTraversalResult {
        case found
        case invalidSplitIdentifier
        case insufficientHeight
    }

    private func appendHeightMaximizeAdjustments(
        targetPaneId: String,
        bounds: CGRect,
        collapsedPaneHeight: CGFloat,
        dividerThickness: CGFloat,
        adjustments: inout [PaneHeightMaximizePlan.Adjustment]
    ) -> HeightMaximizeTraversalResult {
        guard case .split(let split) = self else { return .found }
        let targetInFirst = split.first.containsPane(id: targetPaneId)
        let targetChild = targetInFirst ? split.first : split.second

        switch split.orientation.lowercased() {
        case "vertical":
            guard let splitId = UUID(uuidString: split.id) else {
                return .invalidSplitIdentifier
            }
            let competingChild = targetInFirst ? split.second : split.first
            let availableHeight = max(0, bounds.height - dividerThickness)
            let competingHeight = competingChild.collapsedHeight(
                paneHeaderHeight: collapsedPaneHeight,
                dividerThickness: dividerThickness
            )
            guard competingHeight < availableHeight else {
                return .insufficientHeight
            }
            let targetHeight = availableHeight - competingHeight
            adjustments.append(.init(
                splitId: splitId,
                imposedFirstExtent: targetInFirst ? targetHeight : competingHeight
            ))
            let targetBounds = CGRect(
                x: bounds.minX,
                y: targetInFirst ? bounds.minY : bounds.minY + targetHeight + dividerThickness,
                width: bounds.width,
                height: targetHeight
            )
            return targetChild.appendHeightMaximizeAdjustments(
                targetPaneId: targetPaneId,
                bounds: targetBounds,
                collapsedPaneHeight: collapsedPaneHeight,
                dividerThickness: dividerThickness,
                adjustments: &adjustments
            )

        case "horizontal":
            let firstWidth = bounds.width * CGFloat(split.dividerPosition)
            let targetBounds = targetInFirst
                ? CGRect(x: bounds.minX, y: bounds.minY, width: firstWidth, height: bounds.height)
                : CGRect(x: bounds.minX + firstWidth, y: bounds.minY, width: bounds.width - firstWidth, height: bounds.height)
            return targetChild.appendHeightMaximizeAdjustments(
                targetPaneId: targetPaneId,
                bounds: targetBounds,
                collapsedPaneHeight: collapsedPaneHeight,
                dividerThickness: dividerThickness,
                adjustments: &adjustments
            )

        default:
            return .found
        }
    }

    private func containsPane(id: String) -> Bool {
        switch self {
        case .pane(let pane):
            return pane.id == id
        case .split(let split):
            return split.first.containsPane(id: id) || split.second.containsPane(id: id)
        }
    }

    private func pixelBounds() -> CGRect {
        switch self {
        case .pane(let pane):
            return CGRect(x: pane.frame.x, y: pane.frame.y, width: pane.frame.width, height: pane.frame.height)
        case .split(let split):
            return split.first.pixelBounds().union(split.second.pixelBounds())
        }
    }

    private func collapsedHeight(
        paneHeaderHeight: CGFloat,
        dividerThickness: CGFloat
    ) -> CGFloat {
        switch self {
        case .pane:
            return paneHeaderHeight
        case .split(let split):
            let first = split.first.collapsedHeight(
                paneHeaderHeight: paneHeaderHeight,
                dividerThickness: dividerThickness
            )
            let second = split.second.collapsedHeight(
                paneHeaderHeight: paneHeaderHeight,
                dividerThickness: dividerThickness
            )
            return split.orientation.lowercased() == "vertical"
                ? first + dividerThickness + second
                : max(first, second)
        }
    }
}
