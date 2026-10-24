import AppKit
import os

/// cmux (cx-sya4n: blinking lights give a teammate headaches; nothing loops under Reduce
/// Motion): the vendored transcript's caret and typing row read this.
extension MessagesLabHomeView {
    /// The host's Reduce Motion pin (cmux-next mirrors `Motion.reduceMotionOverride`, the
    /// tests' pin); nil reads the system setting. The vendored code reads it when a loop starts;
    /// a loop already running changes only when the host calls ``applyReduceMotion()``.
    nonisolated public static var reduceMotionOverride: Bool? {
        get { reduceMotionPin.withLock { $0 } }
        set { reduceMotionPin.withLock { $0 = newValue } }
    }
    // A lock, not an actor: the vendored code reads the pin synchronously from any thread, and
    // it guards one Bool? value (no list, no callbacks).
    nonisolated private static let reduceMotionPin = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    /// Reduce Motion: the caret holds solid, the typing dots stand still and do not breathe.
    nonisolated static var reducesMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Stills (or restarts) the caret blink and every typing row under this view, for the Reduce
    /// Motion setting now (``reducesMotion``).
    ///
    /// The view observes no notification: its host calls this after the system setting or the
    /// pin changed (cmux-next: `HomeReduceMotion`, one observer for every Home view).
    public func applyReduceMotion() {
        var views: [NSView] = [self]
        while let view = views.popLast() {
            if let field = view as? FieldTextView { field.applyReduceMotion() }
            views += view.subviews
        }
        var layers: [CALayer] = layer.map { [$0] } ?? []
        while let layer = layers.popLast() {
            if let cell = layer.delegate as? RowCell { cell.applyReduceMotion() }
            layers += layer.sublayers ?? []
        }
    }
}

extension FieldTextView {
    /// The blink stops under Reduce Motion and starts again after it, while the caret shows.
    func applyReduceMotion() {
        let state = caretState
        if MessagesLabHomeView.reducesMotion {
            caretLayer.removeAnimation(forKey: "blink")
            caretLayer.opacity = 1
        } else if state.shown, !state.blinks {
            startBlink()
        }
    }
}

extension RowCell {
    /// A typing row's dots stand still and its breath stops under Reduce Motion; after it they
    /// run again from now.
    func applyReduceMotion() {
        guard dots.contains(where: { $0.sublayers?.first?.animation(forKey: "dots") != nil }) else { return }
        let now = CACurrentMediaTime()
        startTypingDots(begin: now)
        startTypingBreath(insert: now)
    }
}
