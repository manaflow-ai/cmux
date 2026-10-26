import AppKit
import os

/// cmux (cx-sya4n: blinking lights give a teammate headaches; nothing loops under Reduce
/// Motion): the vendored transcript's caret and typing row read this.
extension MessagesLabHomeView {
    /// Reduce Motion as the host resolves it (cmux-next pushes `Motion.reduceMotion`: the system
    /// setting, calm mode and the tests' pin); nil reads the system setting. The host also tells
    /// live views of a change (``applyReduceMotion()``): this view observes nothing itself.
    nonisolated public static var reduceMotionOverride: Bool? {
        get { reduceMotionPin.withLock { $0 } }
        set { reduceMotionPin.withLock { $0 = newValue } }
    }
    nonisolated private static let reduceMotionPin = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    /// Reduce Motion: the caret holds solid, the typing dots stand still and do not breathe.
    nonisolated static var reducesMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Stills (or restarts) the caret blink and every typing row under this view: the host calls it
    /// after it pushed a new ``reduceMotionOverride``.
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
