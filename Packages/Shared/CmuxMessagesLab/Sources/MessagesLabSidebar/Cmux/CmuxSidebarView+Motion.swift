import AppKit
import os

/// cmux (cx-sya4n: Austin gets headaches from blinking lights; nothing loops under
/// Reduce Motion): the vendored list's typing bubble reads this.
extension CmuxSidebarView {
    /// The host's Reduce Motion pin (cmux-next mirrors `Motion.reduceMotionOverride`, the
    /// tests' pin); nil reads the system setting.
    nonisolated public static var reduceMotionOverride: Bool? {
        get { reduceMotionPin.withLock { $0 } }
        set { reduceMotionPin.withLock { $0 = newValue } }
    }
    nonisolated private static let reduceMotionPin = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    /// Reduce Motion: the typing bubble's dots stand still.
    nonisolated static var reducesMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
