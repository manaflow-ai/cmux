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
    func beginSession() -> Bool

    /// Types one finalized delta into the pinned target.
    ///
    /// - Returns: `false` when the target no longer exists; the controller
    ///   ends the session.
    func insertFinalizedText(_ text: String) -> Bool

    /// Releases the pinned target at session end.
    func endSession()
}
