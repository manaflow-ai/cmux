import Bonsplit
import SwiftUI

/// Divides one axis proportionally to tmux's assigned cells, interleaving
/// fixed-thickness divider strips between child panes.
struct RemoteTmuxWeightedSplitLayout: Layout {
    let axis: Axis
    let weights: [CGFloat]
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let childCount = (subviews.count + 1) / 2
        let total = max(1, weights.reduce(0, +))
        let span = axis == .horizontal ? bounds.width : bounds.height
        let usable = max(1, span - spacing * CGFloat(max(0, childCount - 1)))
        var cursor = axis == .horizontal ? bounds.minX : bounds.minY
        var childIndex = 0
        for (index, subview) in subviews.enumerated() {
            let isStrip = index.isMultiple(of: 2) == false
            let dimension: CGFloat
            if isStrip {
                dimension = spacing
            } else {
                let weight = childIndex < weights.count ? weights[childIndex] : 1
                dimension = usable * weight / total
                childIndex += 1
            }
            let frame: CGRect = axis == .horizontal
                ? CGRect(x: cursor, y: bounds.minY, width: dimension, height: bounds.height)
                : CGRect(x: bounds.minX, y: cursor, width: bounds.width, height: dimension)
            subview.place(
                at: frame.origin, anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
            cursor += dimension
        }
    }
}
