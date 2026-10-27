import AppKit
import os

/// cmux (cx-sya4n: blinking lights give a teammate headaches; nothing loops under Reduce
/// Motion): the vendored transcript's caret and typing row read this.
extension MessagesLabHomeView {
    /// Reduce Motion as the host resolves it (cmux-next pushes `Motion.reduceMotion`: the system
    /// setting, calm mode and the tests' pin); nil reads the system setting. The host also tells
    /// live views of a change (``applyReduceMotion()``): this view observes nothing itself.
    nonisolated public static var reduceMotionOverride: Bool? {
        get { motionPins.withLock { $0.reduceMotion } }
        set { motionPins.withLock { $0.reduceMotion = newValue } }
    }

    /// The host's own reason for the ambient loops (the typing dots and breath) to hold still,
    /// besides Reduce Motion: cmux-next pushes `!Motion.home.animatesLoops` (Energy Saver, the
    /// animation speed off, Home's motion off). The caret is the person's own field and does not
    /// read it. The host also tells live views of a change (``applyReduceMotion()``).
    nonisolated public static var hostStillsLoops: Bool {
        get { motionPins.withLock { $0.stillsLoops } }
        set { motionPins.withLock { $0.stillsLoops = newValue } }
    }

    /// Whether the message box's glass fades when a message is sent (a Core Animation opacity
    /// pulse). cmux-next sets its motion gate (`Motion.home.animatesFades`: the motion switches,
    /// the speed and Reduce Motion); off, the box stays opaque. The default fades, as Messages does.
    public var fadeMotionGate: @MainActor () -> Bool {
        get { controller.host.fieldChrome.animatesFade }
        set { controller.host.fieldChrome.animatesFade = newValue }
    }

    /// What the host pushed: one lock for both values.
    private struct MotionPins: Sendable {
        var reduceMotion: Bool?
        var stillsLoops = false
    }
    nonisolated private static let motionPins = OSAllocatedUnfairLock(initialState: MotionPins())

    /// Reduce Motion: the caret holds solid, the typing dots stand still and do not breathe.
    nonisolated static var reducesMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The typing dots stand still and do not breathe: Reduce Motion or ``hostStillsLoops``.
    nonisolated static var stillsLoops: Bool { hostStillsLoops || reducesMotion }

    /// Stills (or restarts) the caret blink and every typing row under this view: the host calls it
    /// after it pushed a new ``reduceMotionOverride`` or ``hostStillsLoops``.
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
            loops.detach(caretLayer, key: "blink")
            caretLayer.opacity = 1
        } else if state.shown, !state.blinks {
            startBlink()
        }
    }
}

extension RowCell {
    /// A typing row's dots stand still and its breath stops under Reduce Motion; after it they
    /// run again from now. It reads the attached dots, not the layers: an occluded window keeps its
    /// loops off them, and the breath must still come back when it shows (p14-energy-115).
    func applyReduceMotion() {
        guard typingDotsAttached else { return }
        let now = CACurrentMediaTime()
        startTypingDots(begin: now)
        startTypingBreath(insert: now)
    }
}
