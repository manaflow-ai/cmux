public import AppKit

/// A compact, human-readable description of a key event for shortcut-routing
/// debug logs: the active device-independent modifiers followed by the
/// characters-ignoring-modifiers (or the event type for non-key events) and the
/// raw key code, for example `Cmd+Shift+'a'(0)`.
///
/// The cmux app target used to inline this as a `static func keyDescription(_:)`
/// on a private `NSWindow` extension, called from a dozen `#if DEBUG` shortcut
/// log lines as `NSWindow.keyDescription(event)`. It reads only the event's
/// modifier flags, type, characters, and key code, with no `NSWindow`,
/// `Workspace`, or `AppDelegate` reach, so it belongs here next to the shortcut
/// event decode and routing that share its keystroke hot path.
///
/// It is modeled as a computed property on the ``AppKit/NSEvent`` it formats
/// (call sites read `event.cmuxKeyDescription`) rather than a static-method
/// utility, so no caseless namespace is introduced. The body is a byte-faithful
/// lift of the original formatter.
extension NSEvent {
    /// The active modifiers, characters, and key code formatted for debug logs,
    /// e.g. `Cmd+Opt+'c'(8)`.
    public var cmuxKeyDescription: String {
        var parts: [String] = []
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { parts.append("Cmd") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.option) { parts.append("Opt") }
        if flags.contains(.control) { parts.append("Ctrl") }
        let chars: String
        if type == .keyDown || type == .keyUp {
            chars = charactersIgnoringModifiers ?? "?"
        } else {
            chars = String(describing: type)
        }
        parts.append("'\(chars)'(\(keyCode))")
        return parts.joined(separator: "+")
    }
}
