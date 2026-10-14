#if os(iOS)
import Observation
import SwiftUI
import UIKit

/// The grid cards' swipe-to-close offsets (shared by the grid and the
/// terminal layer, which draws the active terminal's card).
@MainActor
@Observable
final class CardSwipeState {
    /// Horizontal offset per card key.
    private(set) var offsets: [String: CGFloat] = [:]
    /// Opacity per card key (Reduce Motion crossfades).
    private(set) var opacities: [String: Double] = [:]
    /// Lift scale per card key (1.09 while dragged).
    private(set) var scales: [String: CGFloat] = [:]

    func offset(_ key: String) -> CGFloat { offsets[key] ?? 0 }
    func opacity(_ key: String) -> Double { opacities[key] ?? 1 }
    func scale(_ key: String) -> CGFloat { scales[key] ?? 1 }

    private func spring(_ s: ZoomSpring) -> Animation { .spring(response: s.response, dampingFraction: s.damping) }

    func track(_ key: String, translation: CGFloat, reduceMotion: Bool) {
        if !reduceMotion, scales[key] == nil {
            withAnimation(spring(CardSwipe.lift)) { scales[key] = CardSwipe.liftScale }
        }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            offsets[key] = CardSwipe.offset(translation: translation)
            opacities[key] = nil
        }
    }

    /// Release: keep going left and close, or spring back. `close` runs at
    /// once and reports whether the host closed the tab; until then the
    /// card's slot stays (no reflow). Refused: the card comes back. With
    /// Reduce Motion nothing slides after release: the card fades out where
    /// it is, or reappears at its slot with a 0.18 s fade.
    func release(_ key: String, velocity: CGFloat, card: CGRect, reduceMotion: Bool, close: @escaping () async -> Bool) {
        let offset = offsets[key] ?? 0
        if CardSwipe.commits(offset: offset, velocity: velocity, cardWidth: card.width) {
            if reduceMotion {
                withAnimation(.easeInOut(duration: CardSwipe.reduceMotionFade)) { opacities[key] = 0 }
            } else {
                let target = CardSwipe.flyOffOffset(cardMinX: card.minX, cardWidth: card.width)
                withAnimation(.linear(duration: CardSwipe.flyOffDuration(distance: target - offset, velocity: velocity))) {
                    offsets[key] = target
                }
            }
            Task { [weak self] in
                let closed = await close()
                guard let self else { return }
                if closed {
                    self.offsets[key] = nil
                    self.opacities[key] = nil
                    self.scales[key] = nil
                } else {
                    self.comeBack(key, reduceMotion: reduceMotion)
                }
            }
        } else {
            comeBack(key, reduceMotion: reduceMotion)
        }
    }

    func cancel(_ key: String, reduceMotion: Bool) { comeBack(key, reduceMotion: reduceMotion) }

    /// Back to the card's slot: the snap-back and settle springs, or (Reduce
    /// Motion) a 0.18 s fade in at the slot with no movement.
    private func comeBack(_ key: String, reduceMotion: Bool) {
        if reduceMotion {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                offsets[key] = 0
                scales[key] = nil
                opacities[key] = 0
            }
            withAnimation(.easeInOut(duration: CardSwipe.reduceMotionFade)) { opacities[key] = 1 }
        } else {
            withAnimation(spring(CardSwipe.snapBack)) {
                offsets[key] = 0
                opacities[key] = 1
            }
            withAnimation(spring(CardSwipe.settle)) { scales[key] = 1 } completion: { [weak self] in
                if self?.offsets[key] == 0 { self?.scales[key] = nil }
            }
        }
    }
}

enum CardSwipePhase {
    case changed(translation: CGFloat)
    case ended(translation: CGFloat, velocity: CGFloat)
    case cancelled
}

/// A horizontal pan on a card: begins only when the drag is more
/// horizontal than vertical, so a vertical drag still scrolls the grid.
struct CardSwipeGesture: UIGestureRecognizerRepresentable {
    var onPhase: (CardSwipePhase) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let g = UIPanGestureRecognizer()
        g.maximumNumberOfTouches = 1
        g.delegate = context.coordinator
        return g
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func handleUIGestureRecognizerAction(_ g: UIPanGestureRecognizer, context: Context) {
        let dx = g.translation(in: g.view).x
        switch g.state {
        case .began, .changed: onPhase(.changed(translation: dx))
        case .ended: onPhase(.ended(translation: dx, velocity: g.velocity(in: g.view).x))
        case .cancelled, .failed: onPhase(.cancelled)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y)
        }

        /// The grid's scroll view waits for this pan to fail (it fails at
        /// once for a vertical drag), so a horizontal drag is never taken by
        /// the scroller first.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer && other.view is UIScrollView
        }
    }
}
#endif
