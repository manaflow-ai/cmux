public import AppKit

/// How ``ShortcutHintOverlayView`` brings its chips in and out: a modifier
/// hold fades the chips in, a release (or a key press) fades them out, so
/// hints never pop.
///
/// The overlay hands every new chip to ``fadeIn(_:in:)`` once it is placed,
/// and every chip that leaves to ``fadeOut(_:in:completion:)``; the chip
/// stays in the overlay until `completion` runs. Tests pass a recording fake
/// through ``ShortcutHintOverlayView/init(fader:)``.
@MainActor
public protocol ShortcutHintChipFading {
    /// Brings `chips` (already placed, alpha 0) to full opacity.
    ///
    /// - Parameters:
    ///   - chips: The chips that just appeared.
    ///   - overlay: The overlay that draws them (its window decides whether motion runs).
    func fadeIn(_ chips: [NSView], in overlay: NSView)

    /// Takes `chips` to alpha 0, then calls `completion`, which removes them.
    ///
    /// - Parameters:
    ///   - chips: The chips that are leaving.
    ///   - overlay: The overlay that draws them.
    ///   - completion: Runs once the chips are invisible.
    func fadeOut(_ chips: [NSView], in overlay: NSView, completion: @escaping @MainActor @Sendable () -> Void)
}
