/// A compact integer identity for the view that owns the keyboard's first
/// responder on the iOS terminal input path.
///
/// ``DiagnosticEvent`` carries only integer payloads (no allocated strings), so
/// the first-responder *class* is encoded as one of these small raw values and
/// decoded back to a human-readable name by `scripts/decode-ios-diagnostic.py`.
/// The keyboard-input instrumentation stamps this into the `a`/`b` slots of the
/// ``DiagnosticEventCode/inputKeyboardUp``, ``DiagnosticEventCode/inputDeleteBackward``,
/// and ``DiagnosticEventCode/inputBecomeFirstResponder`` events so a device
/// dogfood reveals *which* view the software keyboard actually drives.
///
/// The central question this answers: is ``DiagnosticEventCode/inputDeleteBackward``
/// firing on the same view the keyboard came up over, or has first responder
/// moved elsewhere between keyboard-up and the keystroke (an iOS analog of the
/// Mac's `keyRepair` focus-steal)?
public enum InputResponderIdentity: Int, Sendable, Codable, CaseIterable {
    /// No first responder, or it could not be resolved.
    case none = 0
    /// The expected terminal keyboard proxy (`TerminalInputTextView`). The
    /// keyboard is driving the view we instrument; the bug is then in
    /// auto-repeat/dictation behavior, not in *who* holds focus.
    case terminalInputProxy = 1
    /// The Metal/IOSurface terminal surface itself (`GhosttySurfaceView`).
    case ghosttySurface = 2
    /// A `UITextField` (e.g. an unexpected SwiftUI/text field stealing focus).
    case uiTextField = 3
    /// A `UITextView`.
    case uiTextView = 4
    /// Some other `UIResponder` subclass not in this list. The decoder pairs this
    /// with the human-readable class name carried in the companion string log
    /// (`anchormux`) for the same event.
    case other = 9
}
