import Bonsplit
import SwiftUI

/// Places every subview at a precomputed absolute frame (tmux's pane sizes in
/// points). The layout's own size is always exactly the size its parent gives
/// it, so pane frames cannot recursively resize their parent while tmux is
/// still applying a requested size.
struct RemoteTmuxImposedFrameLayout: Layout {
    let frames: [CGRect]

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        for (index, subview) in subviews.enumerated() {
            // Count mismatch would mean the body's subview list drifted from
            // `frames`; hide the orphan rather than guessing a position.
            guard index < frames.count else {
                subview.place(at: bounds.origin, anchor: .topLeading, proposal: .zero)
                continue
            }
            let frame = frames[index]
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }
}
