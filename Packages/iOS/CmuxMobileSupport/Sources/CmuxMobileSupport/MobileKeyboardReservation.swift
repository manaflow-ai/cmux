public import CoreGraphics

/// A keyboard-driven bottom reservation for a view that should only track
/// docked keyboards.
public struct MobileKeyboardReservation: Equatable, Sendable {
    /// The height of the view covered from its bottom edge by the keyboard.
    public let height: CGFloat

    /// Returns the height of `viewFrameInWindow` covered from the bottom edge by
    /// `keyboardFrameInWindow`.
    ///
    /// Floating or split iPad keyboards can intersect the middle of a view while
    /// leaving its bottom edge clear. Those keyboards should not lift a bottom
    /// composer, so `height` is zero unless the keyboard reaches the view's
    /// bottom edge.
    public init(
        keyboardFrameInWindow keyboardFrame: CGRect,
        viewFrameInWindow viewFrame: CGRect,
        edgeTolerance: CGFloat = 1
    ) {
        guard !keyboardFrame.isNull,
              !keyboardFrame.isEmpty,
              !viewFrame.isNull,
              !viewFrame.isEmpty
        else {
            height = 0
            return
        }

        let intersection = viewFrame.intersection(keyboardFrame)
        guard !intersection.isNull,
              !intersection.isEmpty,
              keyboardFrame.maxY >= viewFrame.maxY - edgeTolerance
        else {
            height = 0
            return
        }

        height = max(0, intersection.height)
    }
}
