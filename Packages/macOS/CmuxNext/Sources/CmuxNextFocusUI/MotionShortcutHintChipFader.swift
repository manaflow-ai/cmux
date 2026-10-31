public import AppKit
import CmuxNextDesign

/// The production ``ShortcutHintChipFading``: the `fadeIn` and `fadeOut`
/// motion tokens (`MotionFade`), so `ui.animationSpeed` and Reduce Motion
/// apply, and an offscreen window snaps.
@MainActor
public struct MotionShortcutHintChipFader: ShortcutHintChipFading {
    /// Creates the fader; it holds no state.
    public init() {}

    public func fadeIn(_ chips: [NSView], in overlay: NSView) {
        Motion.overlays.animate(.fadeIn, in: overlay) {
            for chip in chips { chip.animator().alphaValue = 1 }
        }
    }

    public func fadeOut(_ chips: [NSView], in overlay: NSView, completion: @escaping @MainActor @Sendable () -> Void) {
        Motion.overlays.animate(.fadeOut, in: overlay, {
            for chip in chips { chip.animator().alphaValue = 0 }
        }, completion: completion)
    }
}
