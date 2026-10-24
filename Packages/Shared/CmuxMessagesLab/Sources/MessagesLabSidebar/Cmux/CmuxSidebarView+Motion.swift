import AppKit
import os

/// cmux (cx-sya4n: blinking lights give a teammate headaches; nothing loops under Reduce
/// Motion): the vendored list's typing bubble reads this.
extension CmuxSidebarView {
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

    /// Reduce Motion: the typing bubble's dots stand still.
    nonisolated static var reducesMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The host's motion gate for movement (cmux-next: `Motion.animatesMovement`, so the
    /// animation speed `off` and the motion settings also apply); nil: only Reduce Motion
    /// decides. Read when a movement starts.
    public static var movementGate: (@MainActor () -> Bool)?

    /// Movement (the pin drag's lift, slides and landing) animates: not Reduce Motion, and the
    /// host's gate allows it. When false the change applies in one frame.
    static var animatesMovement: Bool { !reducesMotion && (movementGate?() ?? true) }

    /// Stills (or restarts) every typing bubble in the list, for the Reduce Motion setting now
    /// (``reducesMotion``).
    ///
    /// The list observes no notification: its host calls this after the system setting or the
    /// pin changed (cmux-next: `HomeReduceMotion`, one observer for every Home view).
    public func applyReduceMotion() {
        var layers: [CALayer] = layer.map { [$0] } ?? []
        while let layer = layers.popLast() {
            if let bubble = layer as? SidebarTypingLayer { bubble.animate() }
            layers += layer.sublayers ?? []
        }
    }
}
