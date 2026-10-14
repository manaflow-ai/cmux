import AppKit

/// cmux (cx-sya4n: Austin gets headaches from blinking lights; nothing loops under
/// Reduce Motion): the vendored list's typing bubble reads this.
extension CmuxSidebarView {
    /// The host's Reduce Motion pin (cmux-next mirrors `Motion.reduceMotionOverride`, the
    /// tests' pin); nil reads the system setting.
    nonisolated(unsafe) public static var reduceMotionOverride: Bool?

    /// Reduce Motion: the typing bubble's dots stand still.
    nonisolated static var reducesMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
