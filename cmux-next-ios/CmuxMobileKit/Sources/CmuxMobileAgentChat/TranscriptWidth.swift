import SwiftUI

/// Takes exactly the proposed width, whatever its content asks for, and lays its content
/// out at that width and at its ideal height (never a proposed height).
///
/// A `VStack` is as wide as its widest child. At accessibility sizes one row that could
/// not shrink (the answer action row's 90 pt icons and duration) made a turn 466 pt wide
/// in a 362 pt column. The transcript was measured with text wrapped at 362 pt but drawn
/// with text wrapped at 466 pt, so it drew thousands of points shorter than its measured
/// height: a blank band above the composer at the bottom of a long chat (chat-feed
/// review F3). Each turn and the transcript root sit in this layout, so a row that
/// overflows overflows alone and the measured height is the drawn height.
///
/// The height: given its own ideal height as a concrete proposal, the transcript's
/// stacks came out about 300 pt shorter at AX5 than with no height proposed (they hand
/// out a finite height among their rows), so the content is always laid out at its
/// ideal height, the same proposal the measurement used.
struct ProposedWidthLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let first = subviews.first else { return .zero }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? first.sizeThatFits(.unspecified).width
        let size = first.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}
