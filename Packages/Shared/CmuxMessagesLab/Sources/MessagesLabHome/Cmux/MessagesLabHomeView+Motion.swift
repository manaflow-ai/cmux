import AppKit

/// cmux (cx-sya4n: Austin gets headaches from blinking lights; nothing loops under
/// Reduce Motion): the vendored transcript's caret and typing row read this.
extension MessagesLabHomeView {
    /// The host's Reduce Motion pin (cmux-next mirrors `Motion.reduceMotionOverride`, the
    /// tests' pin); nil reads the system setting.
    nonisolated(unsafe) public static var reduceMotionOverride: Bool?

    /// Reduce Motion: the caret holds solid, the typing dots stand still and do not breathe.
    nonisolated static var reducesMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
