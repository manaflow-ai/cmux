import SwiftUI

/// How tall the composer's slash-command list may be: the room between its ceiling (under
/// the chat's header, and under whatever the bottom stack shows over the composer) and the
/// list's own bottom edge, the composer card's top. Both are window y. The chat's dock lays
/// its stack out at its ideal height and proposes none (`ProposedWidthLayout`), so twenty
/// commands once asked for 880 pt on any screen; the list now takes this height and
/// scrolls the rest, keeping every command.
struct SlashSuggestionsBound: Equatable {
    /// A row's least height (a touch target); rows grow past it with Dynamic Type.
    static let minRowHeight: CGFloat = 44
    /// With no measured room (a host that sets no ceiling, or before the first layout):
    /// five rows and half of the sixth, so the list reads as scrollable.
    static let fallbackHeight: CGFloat = minRowHeight * 5.5

    /// Window y the list may not rise above; nil when the host does not say.
    var ceiling: CGFloat?
    /// Window y of the list's bottom edge; nil before it is laid out.
    var bottom: CGFloat?

    /// Never less than one row, so the list still shows a command (and scrolls) when the
    /// room above the keyboard is smaller than that.
    var maxHeight: CGFloat {
        guard let ceiling, let bottom else { return Self.fallbackHeight }
        return max(Self.minRowHeight, bottom - ceiling)
    }
}

/// Lays its one subview out at its ideal height for the proposed width, capped at
/// `maxHeight`, and places it at that concrete height. A vertical `ScrollView`'s ideal height
/// is its content's, so the list is as tall as its rows while they fit and `maxHeight`
/// (scrolling) once they don't, whatever height its ancestors propose.
struct CappedHeightLayout: Layout {
    var maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let first = subviews.first else { return .zero }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let ideal = first.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width ?? ideal.width, height: min(ideal.height, max(0, maxHeight)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
