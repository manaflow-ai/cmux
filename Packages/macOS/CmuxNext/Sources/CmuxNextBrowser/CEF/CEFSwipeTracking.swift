import AppKit

/// AppKit's swipe tracking (`-[NSEvent trackSwipeEventWithOptions:...]`) as a main-actor callback: the seam
/// adapter `CEFSwipeNavigation` starts a tracked swipe through. The handler reports the swipe's amount (positive
/// is Back: content dragged right), its phase and whether the animation completed.
@MainActor
struct CEFSwipeTracking {
    let changed: @MainActor (_ amount: CGFloat, _ phase: NSEvent.Phase, _ isComplete: Bool) -> Void

    init(_ changed: @escaping @MainActor (_ amount: CGFloat, _ phase: NSEvent.Phase, _ isComplete: Bool) -> Void) {
        self.changed = changed
    }

    /// Tracks the swipe `event` starts. A side with no page clamps at 0, so AppKit dampens past it: the rubber band.
    func start(with event: NSEvent, canBack: Bool, canForward: Bool) {
        let changed = changed
        event.trackSwipeEvent(options: [.lockDirection], dampenAmountThresholdMin: canForward ? -1 : 0,
                              max: canBack ? 1 : 0) { amount, phase, isComplete, _ in
            MainActor.assumeIsolated { // main-proof: AppKit calls the swipe handler on the main thread, from event tracking
                changed(amount, phase, isComplete)
            }
        }
    }
}
