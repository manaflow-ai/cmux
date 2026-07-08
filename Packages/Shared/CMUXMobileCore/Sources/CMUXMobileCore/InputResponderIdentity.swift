/// A compact integer identity for the view that owns the keyboard's first
/// responder on the iOS terminal input path.
///
/// ``DiagnosticEvent`` carries only integer payloads (no allocated strings), so
/// the first-responder *class* is encoded as one of these small raw values and
/// decoded back to a human-readable name by `scripts/decode-ios-diagnostic.py`.
/// The composer-dock instrumentation stamps this into the payload slots of the
/// ``DiagnosticEventCode/composerActiveTransition`` and
/// ``DiagnosticEventCode/composerKeyboardToggleWhilePresented`` events so a
/// captured trace shows *which* view actually holds first responder when the
/// composer opens, closes, or survives a keyboard toggle.
public enum InputResponderIdentity: Int, Sendable, Codable, CaseIterable {
    /// No first responder, or it could not be resolved.
    case none = 0
    /// The expected terminal keyboard proxy (`TerminalInputTextView`). The
    /// keyboard is driving the view we instrument.
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
