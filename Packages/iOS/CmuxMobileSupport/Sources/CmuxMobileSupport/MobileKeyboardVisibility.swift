public import CoreGraphics

/// Whether a keyboard frame represents a visible software keyboard for a view.
///
/// Unlike ``MobileKeyboardReservation``, this intentionally treats floating and
/// split iPad keyboards as visible even when they do not reserve bottom space.
public struct MobileKeyboardVisibility: Equatable, Sendable {
    /// True when the keyboard frame intersects the view frame.
    public let isVisible: Bool

    /// Creates keyboard visibility from normalized window-space frames.
    ///
    /// - Parameters:
    ///   - keyboardFrame: The keyboard frame converted into window coordinates.
    ///   - viewFrame: The view frame converted into the same window coordinates.
    public init(
        keyboardFrameInWindow keyboardFrame: CGRect,
        viewFrameInWindow viewFrame: CGRect
    ) {
        guard !keyboardFrame.isNull,
              !keyboardFrame.isEmpty,
              !viewFrame.isNull,
              !viewFrame.isEmpty
        else {
            isVisible = false
            return
        }

        let intersection = viewFrame.intersection(keyboardFrame)
        isVisible = !intersection.isNull && !intersection.isEmpty
    }
}
