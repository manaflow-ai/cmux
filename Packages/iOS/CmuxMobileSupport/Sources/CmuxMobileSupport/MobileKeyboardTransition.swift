#if canImport(UIKit)
public import Foundation
public import UIKit

/// Keyboard frame-change data normalized from UIKit's keyboard notification payload.
///
/// Use this with `UIResponder.keyboardWillChangeFrameNotification` so layout,
/// content inset, and content offset updates use the exact duration and curve of
/// the system keyboard animation.
public struct MobileKeyboardTransition: Sendable {
    /// The keyboard's initial screen-space frame from the notification payload.
    public let beginFrame: CGRect

    /// The keyboard's final screen-space frame from the notification payload.
    public let endFrame: CGRect

    /// The system keyboard animation duration, in seconds.
    public let duration: TimeInterval

    /// The system keyboard animation curve encoded as `UIView.AnimationOptions`.
    public let animationOptions: UIView.AnimationOptions

    /// The notification's raw `UIKeyboardAnimationCurveUserInfoKey` (7 for
    /// the keyboard's own curve).
    public let curve: Int

    /// Creates a transition from a keyboard frame-change notification.
    ///
    /// - Parameter notification: A `UIResponder.keyboardWillChangeFrameNotification`
    ///   or matching keyboard notification containing UIKit keyboard animation keys.
    public init?(notification: Notification) {
        guard let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return nil
        }
        beginFrame = notification.userInfo?[UIResponder.keyboardFrameBeginUserInfoKey] as? CGRect
            ?? endFrame
        self.endFrame = endFrame
        duration = MobileKeyboardRide.duration(notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey])
        let curveRaw = MobileKeyboardRide.curve(notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey])
        curve = curveRaw
        animationOptions = UIView.AnimationOptions(rawValue: UInt(curveRaw) << 16)
    }

    /// Moves views with the keyboard in the keyboard's own transaction: call
    /// it from a keyboard will-change notification (UIKit posts it inside the
    /// keyboard's animation block), with the notification's duration and curve.
    @MainActor public func rideKeyboard(_ animations: @escaping () -> Void) {
        Self.rideKeyboard(duration: duration, curve: curve, animations: animations)
    }

    /// The keyboard's spring response (``MobileKeyboardRide/keyboardSpringResponse``).
    public static let keyboardSpringResponse = MobileKeyboardRide.keyboardSpringResponse

    /// The UIKit curve value the keyboard posts for its own animation.
    public static let keyboardCurve = MobileKeyboardRide.keyboardCurve

    /// Runs `animations` on the keyboard's own motion, starting now, in the
    /// current transaction.
    ///
    /// A nested timed animation inside the keyboard's block
    /// inherits its duration and curve 7 as a timing function, which is not
    /// the spring the keyboard itself runs: the stack drifted up to several
    /// points off the keyboard's edge mid-flight and settled up to 100 ms
    /// after it (simulator, 11 to 27 frames off per transition). Curve 7 rides
    /// the keyboard's spring instead; any other curve uses the notification's
    /// duration and curve exactly. `duration <= 0` lays out at once.
    ///
    /// Interruptible (`.allowUserInteraction`): without it UIKit drops every
    /// touch on the views the pass moves until the keyboard settles.
    /// `.beginFromCurrentState` starts a reversal from where the views are
    /// drawn. Reduce Motion keeps it: the system keyboard moves either way,
    /// and landing early would part the views from it.
    @MainActor public static func rideKeyboard(
        duration: TimeInterval,
        curve: Int,
        animations: @escaping () -> Void,
        completion: ((Bool) -> Void)? = nil
    ) {
        let ride = MobileKeyboardRide(duration: duration, curve: curve)
        let options = UIView.AnimationOptions(rawValue: ride.optionsRawValue)
        switch ride.motion {
        case .immediate:
            animations()
            completion?(true)
        case let .spring(response):
            // motion: allow the system keyboard's own spring (Reduce Motion does not stop the keyboard).
            UIView.animate(
                springDuration: response, bounce: 0, initialSpringVelocity: 0, delay: 0,
                options: options, animations: animations, completion: completion
            )
        case let .timed(duration, _):
            // motion: allow the notification's own duration and curve (Reduce Motion does not stop the keyboard).
            UIView.animate(
                withDuration: duration, delay: 0, options: options,
                animations: animations, completion: completion
            )
        }
    }

    /// Returns how much of `view` is covered by the keyboard's final frame.
    ///
    /// - Parameter view: The view whose bounds should be compared to the keyboard.
    /// - Returns: The bottom overlap in `view` coordinates, or zero when detached.
    @MainActor public func overlap(in view: UIView) -> CGFloat {
        overlap(of: endFrame, in: view)
    }

    /// Returns how much of `view` is covered by the keyboard's initial frame.
    ///
    /// The begin/end pair identifies the keyboard transition that emitted a later
    /// `didChangeFrame` notification, allowing clients to reject a completion from
    /// a transition superseded by a rapid reversal.
    @MainActor public func beginOverlap(in view: UIView) -> CGFloat {
        overlap(of: beginFrame, in: view)
    }

    @MainActor private func overlap(of frame: CGRect, in view: UIView) -> CGFloat {
        guard let window = view.window else { return 0 }
        let keyboardFrameInWindow = window.convert(frame, from: nil)
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
        // The content follows the system keyboard with its own curve. The keyboard moves under Reduce Motion too,
        // so a jump here would open a gap or cover the composer. motion: allow follows the system keyboard
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
