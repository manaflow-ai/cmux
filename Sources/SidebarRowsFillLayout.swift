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
/// https://github.com/manaflow-ai/cmux/issues/5845).
///
/// This `Layout` takes the viewport height as an explicit input
/// (`viewportHeight`, the floored content height the call site already computes
/// from the scroll geometry) and sizes the empty area from it directly. It does
/// NOT derive the viewport from the layout proposal: a vertical `ScrollView`
/// leaves the scroll-axis height unspecified, and
/// `ProposedViewSize.replacingUnspecifiedDimensions()` would then fall back to a
/// 10pt placeholder, collapsing the empty area to `0` and dropping the blank
/// area below the last row out of the drop/tap target. With the explicit
/// viewport: when the rows fit, rows + empty area exactly fill the viewport (no
/// overflow, overlay scroller stays hidden —
/// https://github.com/manaflow-ai/cmux/issues/3241); when the rows overflow, the
/// empty area is `0` and the document view scrolls. The rows are never measured
/// into SwiftUI state.
///
/// Expects exactly two subviews in order: `[rows, emptyArea]`.
struct SidebarRowsFillLayout: Layout {
    /// The floored viewport height available to the scroll content. The empty
    /// area fills the remainder of this height below the rows.
    let viewportHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let rowsHeight = subviews.first?.sizeThatFits(
            ProposedViewSize(width: width, height: nil)
        ).height ?? 0
        // Fill the viewport when the rows are shorter; grow to the rows' natural
        // height when they overflow it. Driven by the explicit viewport, not the
        // (unspecified in a vertical ScrollView) proposed height.
        return CGSize(width: width, height: max(rowsHeight, viewportHeight))
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
        // Size the empty area against the explicit viewport (or the rows' height
        // when they overflow it), never against `bounds.height` — which could be
        // the rows' natural height alone if the parent placed us at our content
        // size.
        let emptyHeight = SidebarWorkspaceScrollLayout.emptyAreaFillHeight(
            viewportHeight: viewportHeight,
            rowsHeight: rowsHeight
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + rowsHeight),
            proposal: ProposedViewSize(width: bounds.width, height: emptyHeight)
        )
    }
}
