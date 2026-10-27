import AppKit
import os

/// cmux (cx-sya4n: blinking lights give a teammate headaches; nothing loops under Reduce
/// Motion): the vendored list's typing bubble reads this.
extension CmuxSidebarView {
    /// Reduce Motion as the host resolves it (cmux-next pushes `Motion.reduceMotion`: the system
    /// setting, calm mode and the tests' pin); nil reads the system setting. The host also tells
    /// live views of a change (``applyReduceMotion()``): this view observes nothing itself.
    nonisolated public static var reduceMotionOverride: Bool? {
        get { motionPins.withLock { $0.reduceMotion } }
        set { motionPins.withLock { $0.reduceMotion = newValue } }
    }

    /// The host's own reason for the typing bubble's pulse to hold still, besides Reduce Motion:
    /// cmux-next pushes `!Motion.sidebar.animatesLoops` (Energy Saver, the animation speed off, the
    /// sidebar's motion off). The host also tells live views of a change (``applyReduceMotion()``).
    nonisolated public static var hostStillsLoops: Bool {
        get { motionPins.withLock { $0.stillsLoops } }
        set { motionPins.withLock { $0.stillsLoops = newValue } }
    }

    /// What the host pushed: one lock for both values.
    private struct MotionPins: Sendable {
        var reduceMotion: Bool?
        var stillsLoops = false
    }
    nonisolated private static let motionPins = OSAllocatedUnfairLock(initialState: MotionPins())

    /// Reduce Motion: the typing bubble's dots stand still.
    nonisolated static var reducesMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The typing bubble's dots stand still: Reduce Motion or ``hostStillsLoops``.
    nonisolated static var stillsLoops: Bool { hostStillsLoops || reducesMotion }

    /// The host's motion gate for movement (cmux-next: `Motion.animatesMovement`, so the
    /// animation speed `off` and the motion settings also apply); nil: only Reduce Motion
    /// decides. Read when a movement starts.
    public static var movementGate: (@MainActor () -> Bool)?

    /// Movement (the pin drag's lift, slides and landing) animates: not Reduce Motion, and the
    /// host's gate allows it. When false the change applies in one frame.
    static var animatesMovement: Bool { !reducesMotion && (movementGate?() ?? true) }

    /// Stills (or restarts) every typing bubble in the list: the host calls it after it pushed a
    /// new ``reduceMotionOverride``.
    public func applyReduceMotion() {
        var layers: [CALayer] = layer.map { [$0] } ?? []
        while let layer = layers.popLast() {
            if let bubble = layer as? SidebarTypingLayer { bubble.animate() }
            layers += layer.sublayers ?? []
        }
    }
}
