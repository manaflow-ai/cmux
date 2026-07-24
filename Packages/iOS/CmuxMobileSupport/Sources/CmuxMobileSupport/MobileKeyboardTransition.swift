#if canImport(UIKit)
public import Foundation
public import UIKit

/// Keyboard frame-change data normalized from UIKit's keyboard notification payload.
///
/// Use this with `UIResponder.keyboardWillChangeFrameNotification` so layout,
/// content inset, and content offset updates use the exact duration and curve of
/// the system keyboard animation.
public struct MobileKeyboardTransition: Sendable {
    /// The keyboard's final screen-space frame from the notification payload.
    public let endFrame: CGRect

    /// The system keyboard animation duration, in seconds.
    public let duration: TimeInterval

    /// The system keyboard animation curve encoded as `UIView.AnimationOptions`.
    public let animationOptions: UIView.AnimationOptions

    /// Creates a transition from a keyboard frame-change notification.
    ///
    /// - Parameter notification: A `UIResponder.keyboardWillChangeFrameNotification`
    ///   or matching keyboard notification containing UIKit keyboard animation keys.
    public init?(notification: Notification) {
        guard let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return nil
        }
        self.endFrame = endFrame
        duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0
        let curveRaw = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int
            ?? Int(UIView.AnimationCurve.easeInOut.rawValue)
        animationOptions = UIView.AnimationOptions(rawValue: UInt(curveRaw) << 16)
    }

    /// Returns how much of `view` is covered by the keyboard's final frame.
    ///
    /// - Parameter view: The view whose bounds should be compared to the keyboard.
    /// - Returns: The bottom overlap in `view` coordinates, or zero when detached.
    @MainActor public func overlap(in view: UIView) -> CGFloat {
        guard let window = view.window else { return 0 }
        let keyboardFrameInWindow = window.convert(endFrame, from: nil)
        let viewFrameInWindow = view.convert(view.bounds, to: window)
        return MobileKeyboardReservation(
            keyboardFrameInWindow: keyboardFrameInWindow,
            viewFrameInWindow: viewFrameInWindow
        ).height
    }

    /// Returns whether the keyboard is visible to `view`, including floating or
    /// split iPad keyboards that do not reserve bottom layout space.
    @MainActor public func isVisible(in view: UIView) -> Bool {
        guard let window = view.window else { return false }
        let keyboardFrameInWindow = window.convert(endFrame, from: nil)
        let viewFrameInWindow = view.convert(view.bounds, to: window)
        return MobileKeyboardVisibility(
            keyboardFrameInWindow: keyboardFrameInWindow,
            viewFrameInWindow: viewFrameInWindow
        ).isVisible
    }

    /// Runs animations using the keyboard's exact timing curve and duration.
    ///
    /// - Parameters:
    ///   - additionalOptions: Extra animation options to union with the keyboard curve.
    ///   - animations: Layout, inset, and offset mutations to perform in sync.
    ///   - completion: Optional completion called with UIKit's animation result.
    @MainActor public func animate(
        durationOverride: TimeInterval? = nil,
        additionalOptions: UIView.AnimationOptions = [],
        animations: @escaping @MainActor @Sendable () -> Void,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        let options = animationOptions
            .union(additionalOptions)
            .union([.beginFromCurrentState, .allowUserInteraction])
        let animationDuration = durationOverride ?? duration
        guard animationDuration > 0 else {
            animations()
            completion?(true)
            return
        }
        UIView.animate(
            withDuration: animationDuration,
            delay: 0,
            options: options,
            animations: animations,
            completion: completion
        )
    }
}
#endif
