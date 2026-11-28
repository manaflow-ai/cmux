import SwiftUI

/// Motion vocabulary for toast arrival and departure.
///
/// Arrival: the card drifts in from its resting edge while scaling up from
/// 0.86 and de-blurring, on a spring loose enough for one soft overshoot.
/// Departure: a faster, fully damped settle back toward the edge. Reduce
/// Motion collapses both to plain cross-fades.
enum ToastMotion {
    /// The ambient animation that drives presence changes on the overlay.
    static func driver(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeInOut(duration: 0.18)
            : .spring(response: 0.42, dampingFraction: 0.75)
    }

    static func transition(placement: Toast.Placement, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else {
            return .asymmetric(
                insertion: AnyTransition.opacity.animation(.easeInOut(duration: 0.18)),
                removal: AnyTransition.opacity.animation(.easeInOut(duration: 0.15))
            )
        }
        let sign: CGFloat = placement == .top ? -1 : 1
        let anchor: UnitPoint = placement == .top ? .top : .bottom
        let insertion = AnyTransition.modifier(
            active: ToastTransitionModifier(
                offset: 22 * sign, scale: 0.86, blur: 5, opacity: 0, anchor: anchor
            ),
            identity: ToastTransitionModifier.identity(anchor: anchor)
        )
        .animation(.spring(response: 0.44, dampingFraction: 0.72))
        let removal = AnyTransition.modifier(
            active: ToastTransitionModifier(
                offset: 12 * sign, scale: 0.94, blur: 3, opacity: 0, anchor: anchor
            ),
            identity: ToastTransitionModifier.identity(anchor: anchor)
        )
        .animation(.spring(response: 0.25, dampingFraction: 1))
        return .asymmetric(insertion: insertion, removal: removal)
    }
}

struct ToastTransitionModifier: ViewModifier {
    var offset: CGFloat
    var scale: CGFloat
    var blur: CGFloat
    var opacity: CGFloat
    var anchor: UnitPoint

    nonisolated static func identity(anchor: UnitPoint) -> Self {
        Self(offset: 0, scale: 1, blur: 0, opacity: 1, anchor: anchor)
    }

    func body(content: Content) -> some View {
        content
            .offset(y: offset)
            .scaleEffect(scale, anchor: anchor)
            .blur(radius: blur)
            .opacity(opacity)
    }
}
