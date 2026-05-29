import Bonsplit
import CoreGraphics
import Foundation

@MainActor
enum SplitEqualizer {
    struct Result {
        let foundSplit: Bool
        let allSucceeded: Bool

        var didFullyEqualize: Bool { foundSplit && allSucceeded }
    }

    @discardableResult
    static func equalize(
        in node: ExternalTreeNode,
        controller: BonsplitController,
        orientationFilter: String? = nil
    ) -> Result {
        var foundSplit = false
        var allSucceeded = true
        equalize(
            node,
            controller: controller,
            orientationFilter: orientationFilter,
            foundSplit: &foundSplit,
            allSucceeded: &allSucceeded
        )
        return Result(foundSplit: foundSplit, allSucceeded: allSucceeded)
    }

    private static func equalize(
        _ node: ExternalTreeNode,
        controller: BonsplitController,
        orientationFilter: String?,
        foundSplit: inout Bool,
        allSucceeded: inout Bool
    ) {
        switch node {
        case .pane:
            return
        case .split(let splitNode):
            equalize(
                splitNode.first,
                controller: controller,
                orientationFilter: orientationFilter,
                foundSplit: &foundSplit,
                allSucceeded: &allSucceeded
            )
            equalize(
                splitNode.second,
                controller: controller,
                orientationFilter: orientationFilter,
                foundSplit: &foundSplit,
                allSucceeded: &allSucceeded
            )

            if orientationFilter == nil || splitNode.orientation == orientationFilter {
                foundSplit = true
                if let splitId = UUID(uuidString: splitNode.id) {
                    let firstSpanCount = spanCount(in: splitNode.first, along: splitNode.orientation)
                    let secondSpanCount = spanCount(in: splitNode.second, along: splitNode.orientation)
                    let totalSpanCount = firstSpanCount + secondSpanCount
                    let position = CGFloat(firstSpanCount) / CGFloat(totalSpanCount)
                    if !controller.setDividerPosition(position, forSplit: splitId, fromExternal: true) {
                        allSucceeded = false
                    }
                } else {
                    allSucceeded = false
                }
            }
        }
    }

    private static func spanCount(in node: ExternalTreeNode, along orientation: String) -> Int {
        switch node {
        case .pane:
            return 1
        case .split(let splitNode):
            guard splitNode.orientation == orientation else {
                return 1
            }
            let firstSpanCount = spanCount(in: splitNode.first, along: orientation)
            let secondSpanCount = spanCount(in: splitNode.second, along: orientation)
            return firstSpanCount + secondSpanCount
        }
    }
}
