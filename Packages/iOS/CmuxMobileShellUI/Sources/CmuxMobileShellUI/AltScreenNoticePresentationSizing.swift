import SwiftUI

/// Fits the native popover to content measured at its final wrapping width.
/// The system can still clamp the proposal on compact-height screens, where
/// `ViewThatFits` selects the scrollable fallback.
struct AltScreenNoticePresentationSizing: PresentationSizing {
    static let maxWidth: CGFloat = 340

    func proposedSize(
        for root: PresentationSizingRoot,
        context _: PresentationSizingContext
    ) -> ProposedViewSize {
        let contentSize = root.sizeThatFits(
            ProposedViewSize(width: Self.maxWidth, height: nil)
        )
        return ProposedViewSize(width: Self.maxWidth, height: contentSize.height)
    }
}
