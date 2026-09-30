import Foundation

/// Types finalized dictation text into the focus target pinned at session
/// start.
///
/// The app supplies a router conformance that resolves the focused target
/// (terminal surface, native text responder, or editable web content) once
/// in ``beginSession()`` and keeps inserting into that same target for the
/// whole session, so moving focus mid-dictation never scatters text across
/// panes.
@MainActor
public protocol DictationTextInserting: AnyObject {
    /// Pins the insertion target to whatever is focused right now.
    ///
    /// - Returns: `false` when nothing insertable has focus (the session
    ///   must not start).
    func beginSession() async -> Bool

    /// Types one finalized delta into the pinned target.
    ///
    /// The operation does not complete until the target has accepted (or
    /// rejected) the text. This matters for asynchronous targets such as a
    /// `WKWebView`, where reporting success before the JavaScript completion
    /// would allow a failed final segment to settle the session as successful.
    ///
    /// - Returns: `false` when the target no longer exists or rejects the
    ///   insertion; the controller ends the session.
    func insertFinalizedText(_ text: String) async -> Bool

    /// Releases the pinned target at session end.
    func endSession()
}
