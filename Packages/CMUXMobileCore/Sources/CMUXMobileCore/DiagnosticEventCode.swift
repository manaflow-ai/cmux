import Foundation

/// A compact, stable identifier for one kind of diagnostic event.
///
/// The raw value is a small ``UInt16`` so a ``DiagnosticEvent`` stays tiny and
/// an exported log row is a few bytes instead of an interpolated string. New
/// cases append a fresh raw value and never renumber an existing one, so a blob
/// exported by an older build still decodes against a newer reader.
///
/// The cases cover the round-trip seams a dogfooder cares about: connection and
/// pairing outcome, render-grid liveness (silent re-subscribe / stream ended),
/// the input-sequence and byte-gap stalls that surface as "my keystrokes lag",
/// and a generic ``error`` bucket.
public enum DiagnosticEventCode: UInt16, Sendable, Codable, CaseIterable {
    /// A connection attempt to a paired Mac started.
    case connect = 1
    /// Pairing / attach completed successfully.
    case pairOk = 2
    /// Pairing / attach failed.
    case pairFail = 3
    /// The render-grid stream lagged behind (a bounded render-lag counter tick).
    ///
    /// Reserved for the render hot path in `GhosttySurfaceView` (the existing
    /// `oq.render.LAG` site). It is part of the export vocabulary now, but not
    /// emitted from the shell: instrumenting the per-frame render seam is a
    /// deeper injection deferred past P1, and the spec caps render-path
    /// instrumentation at a single bounded counter.
    case renderGridLag = 4
    /// The liveness watchdog forced a re-subscribe after a silent stream.
    case livenessResubscribe = 5
    /// The render-grid push stream ended and fell back to polling.
    case streamEnded = 6
    /// The local input sequence fell behind the remote-applied sequence.
    case inputSeqBehind = 7
    /// A gap was detected in the delivered terminal byte stream.
    case byteGap = 8
    /// A generic error at an instrumented seam.
    case error = 9

    // MARK: iOS keyboard-input instrumentation (hold-backspace + dictation hunt)
    //
    // These eight codes instrument the iOS terminal keyboard-input path so a
    // device dogfood (which the simulator cannot reproduce — no hold-to-repeat,
    // no dictation) captures *why* hold-backspace and dictation fail. Three blind
    // fix attempts (app-buttons, `hasText=true` UITextView, documentless
    // UIView+UIKeyInput+UITextInput) all left both broken; this round gathers
    // evidence instead of guessing the mechanism. Decode the integer payload with
    // `scripts/decode-ios-diagnostic.py`.

    /// The software keyboard came up (`keyboardWillShow`). `a` = the
    /// ``InputResponderIdentity`` raw value of the current first responder at that
    /// instant (which view the keyboard will actually drive). Confirms or kills
    /// the "``TerminalInputTextView`` is not first responder" hypothesis.
    case inputKeyboardUp = 10
    /// ``TerminalInputTextView/deleteBackward()`` was invoked. Logged on *every*
    /// call, so a single held backspace shows as 1 event (no auto-repeat) versus
    /// many (repeat fires but the byte is lost downstream). `a` = the responder
    /// identity at the moment of the call; `b` = 1 if IME marked text was present
    /// (composition-cancel path), else 0.
    case inputDeleteBackward = 11
    /// A DEL byte (0x7F) actually left the surface toward the Mac
    /// (`onBackspace` → `didProduceInput`). Pairing this with
    /// ``inputDeleteBackward`` proves whether N delete calls produced N emitted
    /// bytes: if both counts match the iOS view is correct and the hunt moves
    /// downstream (transport/Mac/render). `ms` = emitted byte count (always 1).
    case inputBackspaceEmitted = 12
    /// ``TerminalInputTextView/insertText(_:)`` was invoked (typed character, IME
    /// commit, or a dictation result block). `a` = UTF-8 byte length of the text;
    /// `b` = 1 if IME marked text was present, else 0. A dictation result arrives
    /// here as one multi-character block, so a non-trivial `a` after a mic tap
    /// proves dictation fired.
    case inputInsertText = 13
    /// UIKit asked this view for a dictation placeholder
    /// (`insertDictationResultPlaceholder()`). This is the *entry* signal that the
    /// mic was tapped and the framework accepted this view as a dictation target.
    /// Its absence after a mic tap proves dictation never engaged the view at all.
    case inputDictationPlaceholder = 14
    /// UIKit removed the dictation placeholder
    /// (`removeDictationResultPlaceholder(_:willInsertResult:)`). `a` = 1 if a
    /// recognized result will be inserted next, else 0. `a == 0` after a mic tap
    /// means recognition produced nothing for this view.
    case inputDictationRemove = 15
    /// ``TerminalInputTextView/becomeFirstResponder()`` returned. `a` = 1 if the
    /// view became first responder, else 0; `b` = the resulting first-responder
    /// identity (``InputResponderIdentity`` raw value).
    case inputBecomeFirstResponder = 16
    /// A committed block of text was routed to a sink (`emitCommittedText`). `a` =
    /// UTF-8 byte length; `b` = the ``InputCommitSink`` raw value (which delegate
    /// path the text took: per-key input, bracketed paste, or an escape
    /// sequence). Lets a dictation result be traced from `insertText` through to
    /// the byte path that reaches the Mac.
    case inputCommitRouted = 17
}
