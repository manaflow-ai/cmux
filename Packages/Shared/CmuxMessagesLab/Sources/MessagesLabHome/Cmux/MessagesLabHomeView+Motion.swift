import AppKit
import os

/// cmux (cx-sya4n: Austin gets headaches from blinking lights; nothing loops under
/// Reduce Motion): the vendored transcript's caret and typing row read this.
extension MessagesLabHomeView {
    /// The host's Reduce Motion pin (cmux-next mirrors `Motion.reduceMotionOverride`, the
    /// tests' pin); nil reads the system setting.
    nonisolated public static var reduceMotionOverride: Bool? {
        get { reduceMotionPin.withLock { $0 } }
        set { reduceMotionPin.withLock { $0 = newValue } }
    }
    nonisolated private static let reduceMotionPin = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    /// Reduce Motion: the caret holds solid, the typing dots stand still and do not breathe.
    nonisolated static var reducesMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
