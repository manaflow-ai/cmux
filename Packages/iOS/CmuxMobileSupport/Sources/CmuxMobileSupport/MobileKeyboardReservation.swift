public import CoreGraphics

/// Computes keyboard-driven bottom reservations for views that should only track
/// docked keyboards.
public enum MobileKeyboardReservation {
    /// Returns the height of `viewFrameInWindow` covered from the bottom edge by
    /// `keyboardFrameInWindow`.
    ///
    /// Floating or split iPad keyboards can intersect the middle of a view while
    /// leaving its bottom edge clear. Those keyboards should not lift a bottom
    /// composer, so this returns zero unless the keyboard reaches the view's
    /// bottom edge.
    public static func bottomDockedHeight(
        keyboardFrameInWindow keyboardFrame: CGRect,
        viewFrameInWindow viewFrame: CGRect,
        edgeTolerance: CGFloat = 1
    ) -> CGFloat {
        guard !keyboardFrame.isNull,
              !keyboardFrame.isEmpty,
              !viewFrame.isNull,
              !viewFrame.isEmpty
        else { return 0 }

        let intersection = viewFrame.intersection(keyboardFrame)
        guard !intersection.isNull,
              !intersection.isEmpty,
              keyboardFrame.maxY >= viewFrame.maxY - edgeTolerance
        else { return 0 }

        return max(0, intersection.height)
    }
}
