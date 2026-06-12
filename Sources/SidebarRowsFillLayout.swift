import SwiftUI

/// Lays the sidebar workspace rows out at their natural height, then stretches a
/// trailing empty drop/tap area to fill the remaining viewport — in one geometry
/// pass, with no whole-content height measurement.
///
/// The previous approach measured the `LazyVStack`'s total height via a
/// `.background` `GeometryReader` and routed it through a `PreferenceKey` into
/// `@State` to size a fixed-height empty area. That preference write during
/// layout fed a non-converging relayout transaction
/// (https://github.com/manaflow-ai/cmux/issues/2586,
/// https://github.com/manaflow-ai/cmux/issues/5764,
/// https://github.com/manaflow-ai/cmux/issues/5845). This `Layout` instead reads
/// its own concrete `bounds` (the parent `.frame(minHeight:)` resolves to the
/// viewport during placement) and derives the empty-area height from it, so the
/// rows are never measured into SwiftUI state. The bounds are always finite, so
/// when the rows fit, rows + empty area exactly fill the viewport (no overflow,
/// overlay scroller stays hidden — https://github.com/manaflow-ai/cmux/issues/3241);
/// when the rows overflow, the empty area is `0` and the document view scrolls.
///
/// Expects exactly two subviews in order: `[rows, emptyArea]`.
struct SidebarRowsFillLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let resolved = proposal.replacingUnspecifiedDimensions()
        let rowsHeight = subviews.first?.sizeThatFits(
            ProposedViewSize(width: resolved.width, height: nil)
        ).height ?? 0
        // Fill the proposed (viewport) height when the rows are shorter; grow to
        // the rows' natural height when they overflow it. The parent
        // `.frame(minHeight:)` supplies the viewport floor.
        return CGSize(width: resolved.width, height: max(rowsHeight, resolved.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let rows = subviews.first else { return }
        let rowsHeight = rows.sizeThatFits(
            ProposedViewSize(width: bounds.width, height: nil)
        ).height
        rows.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            proposal: ProposedViewSize(width: bounds.width, height: rowsHeight)
        )
        guard subviews.count > 1 else { return }
        let emptyHeight = SidebarWorkspaceScrollLayout.emptyAreaFillHeight(
            containerHeight: bounds.height,
            rowsHeight: rowsHeight
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + rowsHeight),
            proposal: ProposedViewSize(width: bounds.width, height: emptyHeight)
        )
    }
}
