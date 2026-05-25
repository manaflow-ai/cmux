import Bonsplit
import CoreGraphics
import Foundation

@MainActor
enum SplitEqualizer {
    private enum Axis: String {
        case horizontal
        case vertical

        init?(orientation: String) {
            self.init(rawValue: orientation.lowercased())
        }
    }

    private struct SpanCounts {
        let horizontal: Int
        let vertical: Int

        static let leaf = SpanCounts(horizontal: 1, vertical: 1)

        func count(along axis: Axis) -> Int {
            switch axis {
            case .horizontal:
                return horizontal
            case .vertical:
                return vertical
            }
        }

        static func split(axis: Axis, first: SpanCounts, second: SpanCounts) -> SpanCounts {
            switch axis {
            case .horizontal:
                return SpanCounts(horizontal: first.horizontal + second.horizontal, vertical: 1)
            case .vertical:
                return SpanCounts(horizontal: 1, vertical: first.vertical + second.vertical)
            }
        }
    }

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
        _ = equalize(
            node,
            controller: controller,
            orientationFilter: orientationFilter,
            foundSplit: &foundSplit,
            allSucceeded: &allSucceeded
        )
        return Result(foundSplit: foundSplit, allSucceeded: allSucceeded)
    }

    @discardableResult
    private static func equalize(
        _ node: ExternalTreeNode,
        controller: BonsplitController,
        orientationFilter: String?,
        foundSplit: inout Bool,
        allSucceeded: inout Bool
    ) -> SpanCounts {
        switch node {
        case .pane:
            return .leaf
        case .split(let splitNode):
            let firstSpans = equalize(
                splitNode.first,
                controller: controller,
                orientationFilter: orientationFilter,
                foundSplit: &foundSplit,
                allSucceeded: &allSucceeded
            )
            let secondSpans = equalize(
                splitNode.second,
                controller: controller,
                orientationFilter: orientationFilter,
                foundSplit: &foundSplit,
                allSucceeded: &allSucceeded
            )

            guard let axis = Axis(orientation: splitNode.orientation) else {
                allSucceeded = false
                return .leaf
            }

            let matchesFilter = orientationFilter.map { axis.rawValue == $0.lowercased() } ?? true
            if matchesFilter {
                foundSplit = true
                if let splitId = UUID(uuidString: splitNode.id) {
                    let firstSpanCount = firstSpans.count(along: axis)
                    let secondSpanCount = secondSpans.count(along: axis)
                    let totalSpanCount = firstSpanCount + secondSpanCount
                    let position = CGFloat(firstSpanCount) / CGFloat(totalSpanCount)
                    if !controller.setDividerPosition(position, forSplit: splitId, fromExternal: true) {
                        allSucceeded = false
                    }
                } else {
                    allSucceeded = false
                }
            }

            return .split(axis: axis, first: firstSpans, second: secondSpans)
        }
    }
}
