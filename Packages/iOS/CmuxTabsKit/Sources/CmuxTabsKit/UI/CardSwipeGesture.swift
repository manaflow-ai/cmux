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
    /// Cards flying off (fading out).
    private(set) var closing: Set<String> = []

    func offset(_ key: String) -> CGFloat { offsets[key] ?? 0 }
    func opacity(_ key: String) -> Double { closing.contains(key) ? 0 : 1 }

    func track(_ key: String, translation: CGFloat) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { offsets[key] = CardSwipe.offset(translation: translation) }
    }

    /// Release: fly off and close, or spring back.
    func release(_ key: String, velocity: CGFloat, card: CGRect, motion: TabsKitTheme.Motion, onClose: @escaping () -> Void) {
        let offset = offsets[key] ?? 0
        if CardSwipe.commits(offset: offset, velocity: velocity, cardWidth: card.width) {
            closing.insert(key)
            withAnimation(motion.resolve(.easeOut(duration: CardSwipe.flyOffDuration))) {
                offsets[key] = CardSwipe.flyOffOffset(cardMinX: card.minX, cardWidth: card.width)
            } completion: { [weak self] in
                onClose()
                // A refused close brings the card back: at its slot, visible.
                self?.offsets[key] = nil
                self?.closing.remove(key)
            }
        } else {
            let s = CardSwipe.snapBack
            withAnimation(motion.resolve(.spring(response: s.response, dampingFraction: s.damping))) { offsets[key] = 0 }
        }
    }

    func cancel(_ key: String, motion: TabsKitTheme.Motion) {
        let s = CardSwipe.snapBack
        withAnimation(motion.resolve(.spring(response: s.response, dampingFraction: s.damping))) { offsets[key] = 0 }
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
