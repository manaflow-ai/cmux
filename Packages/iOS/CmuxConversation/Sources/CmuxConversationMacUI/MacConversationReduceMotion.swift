#if os(macOS)
import AppKit

// Reduce Motion for the conversation's AppKit and Core Animation motion.
// With "Reduce motion" on (System Settings > Accessibility > Display),
// spatial motion (frames, scrolling, springs, slides) lands in its end state
// at once and decorative loops don't start; opacity fades stay, since a
// crossfade is Apple's recommended reduced form (each one is marked
// `motion: allow crossfade` where it is called).

extension NSView {
    /// True while the system's Reduce Motion display option is on.
    static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

@MainActor
extension NSAnimatablePropertyContainer {
    /// `animator()`, or with Reduce Motion on the receiver itself, so a
    /// change made through it lands at once even inside an animation group
    /// (the group's completion handler still runs).
    func animatorUnlessReduceMotion() -> Self {
        NSView.reducesMotion ? self : animator()
    }
}
#endif
