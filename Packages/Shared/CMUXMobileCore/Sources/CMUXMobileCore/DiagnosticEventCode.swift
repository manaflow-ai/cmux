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
    /// A pairing attempt was short-circuited because the device had no network
    /// path (the reachability preflight failed before any connect).
    case pairUnreachable = 10

    // MARK: iOS composer instrumentation (draft-disappears-on-keyboard-dismiss hunt)
    //
    // These five codes discriminate WHY the iMessage-style composer's draft
    // vanishes after the keyboard opens then closes. The draft text itself lives
    // in the store (`terminalInputText`), so the symptom must be one of: the
    // `isComposerPresented` flag toggled off, the composer view torn down + rebuilt
    // while the flag stayed true, the draft cleared at the store, or (the residual)
    // a `TextField`/`@FocusState` render blank. Logging the flag, the draft length,
    // and the composer view's appear/disappear *independently* of the flag lets a
    // single captured trace name which one happened. Raw values 11-17 are reserved
    // for the in-flight keyboard-input instrumentation branch.

    /// The store's `isComposerPresented` flag changed (store `didSet`). `a` = 1 if
    /// the composer is now presented, else 0. An unexpected `a == 0` during a bare
    /// keyboard dismiss is the "flag toggled off" cause.
    case composerPresentedChanged = 18
    /// The store's `terminalInputText` draft changed (store `didSet`). `a` = new
    /// UTF-8 byte length; `b` = 1 if it just went to empty (a clear), else 0. A
    /// clear (`b == 1`) with no submit/sign-out nearby is the "draft cleared at the
    /// store" cause.
    case composerInputTextChanged = 19
    /// ``TerminalComposerView`` appeared (`.onAppear`). Logged independently of
    /// ``composerPresentedChanged`` so a disappear/appear pair with no flag change
    /// reveals a view-recreation bug (the flag stayed true but SwiftUI rebuilt the
    /// view).
    case composerViewAppear = 20
    /// ``TerminalComposerView`` disappeared (`.onDisappear`). A disappear without a
    /// matching ``composerPresentedChanged`` `a == 0` is a view-recreation bug, not
    /// an intentional dismiss.
    case composerViewDisappear = 21
    /// The composer's text field focus changed (`@FocusState`). `a` = 1 focused,
    /// else 0. A focus-lost (`a == 0`) while the flag stayed presented and the view
    /// stayed mounted, yet the field reads empty, isolates the residual
    /// `TextField`/`@FocusState` render-blank case.
    case composerFieldFocusChanged = 22

    // COMPOSER keyboard-toggle edge case (composer shown while the
    // textbox/keyboard is hidden). These pin which transition desyncs the
    // composer-presented flag from the keyboard/first-responder state, and they
    // land in the same `store.diagnosticLog` sink the composer events above use.

    /// `GhosttySurfaceView.setComposerActive` ran. `a` = 1 if the composer just
    /// became active, else 0. `b` = the resolved first-responder owner
    /// (``InputResponderIdentity`` raw value: which view holds first responder at
    /// the transition). `c` = 1 if the terminal input proxy is first responder,
    /// else 0. `ms` = the surface's `keyboardHeight` (points) at the transition. A
    /// trace where `a == 1` but `ms == 0` and no terminal/composer responder owns
    /// FR is the composer-up/keyboard-down desync.
    case composerActiveTransition = 23

    /// The docked bar's keyboard toggle button was tapped while the composer is
    /// presented. `a` = 1 if the terminal input proxy was first responder when
    /// tapped (so the tap would hide the keyboard), else 0. Purely diagnostic:
    /// the keyboard toggle no longer dismisses the composer (the composer
    /// survives a keyboard-down), so this records the tap for trace completeness.
    case composerKeyboardToggleWhilePresented = 24
}
