import AppKit
import CmuxNextDesign

/// Whether a bottom-left card shows, with its entrance and exit
/// (``SidebarCardTransition``): the update status notice and the staged
/// update card own one each.
///
/// Showing a hidden card unhides it and plays the entrance at its first
/// layout with a size. Hiding a card that was on screen plays the exit and
/// hides it when the exit ends; meanwhile ``isLeaving`` is true and the slot
/// keeps the card where it was. Showing it again mid-exit cancels the exit.
@MainActor
final class SidebarCardPresence {
    private weak var view: NSView?
    private let policy: @MainActor () -> MotionPolicy
    /// The card plays its exit and is hidden when it ends.
    private(set) var isLeaving = false
    private var pendingEnter = false
    /// The card was laid out with a size since it last showed (it has been drawn).
    private var laidOut = false
    /// Bumped by every show or hide, so a stale exit's completion does nothing.
    private var generation = 0
    /// The next hide skips the exit: the card goes in one frame (Hide under Reduce Motion).
    var hidesNextAtOnce = false

    /// - Parameters:
    ///   - view: The card.
    ///   - policy: The motion settings, read at each change (`Motion.policy`).
    init(_ view: NSView, policy: @escaping @MainActor () -> MotionPolicy = { Motion.overlays.policy }) {
        self.view = view
        self.policy = policy
    }

    var transition: SidebarCardTransition { SidebarCardTransition(policy: policy()) }

    /// Shows the card (with the entrance) or hides it (after the exit).
    func setShown(_ shown: Bool) {
        guard let view else { return }
        if shown {
            hidesNextAtOnce = false
            guard view.isHidden || isLeaving else { return }
            generation += 1
            if isLeaving {
                // Back before it had gone: from where it is now to fully shown.
                isLeaving = false
                transition.enter(view)
            } else {
                view.isHidden = false
                pendingEnter = true
                view.needsLayout = true
            }
            return
        }
        guard !view.isHidden, !isLeaving else { return }
        generation += 1
        pendingEnter = false
        let atOnce = hidesNextAtOnce
        hidesNextAtOnce = false
        guard laidOut, !atOnce else {
            laidOut = false
            view.isHidden = true
            view.superview?.needsLayout = true
            return
        }
        isLeaving = true
        let generation = generation
        transition.exit(view) { [weak self] in
            guard let self, let view = self.view, generation == self.generation else { return }
            self.isLeaving = false
            self.laidOut = false
            view.isHidden = true
            self.transition.clear(view.layer)
            view.superview?.needsLayout = true
        }
    }

    /// Call from the card's `layout()`: plays a pending entrance once the card has a size.
    func didLayout() {
        guard let view, !view.isHidden, !view.bounds.isEmpty else { return }
        laidOut = true
        guard pendingEnter else { return }
        pendingEnter = false
        transition.enter(view)
    }
}
