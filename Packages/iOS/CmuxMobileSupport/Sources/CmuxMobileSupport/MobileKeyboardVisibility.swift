public import CoreGraphics

/// Whether a keyboard frame represents a visible software keyboard for a view.
///
/// Unlike ``MobileKeyboardReservation``, this intentionally treats floating and
/// split iPad keyboards as visible even when they do not reserve bottom space.
public struct MobileKeyboardVisibility: Equatable, Sendable {
    public let isVisible: Bool

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
