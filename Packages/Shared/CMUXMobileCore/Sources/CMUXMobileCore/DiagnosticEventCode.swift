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

    // MARK: App transport lifecycle

    /// A transport dial started. `a` is ``DiagnosticTransportKind`` and `c` is
    /// the positive, process-local attempt ID shared by the matching dial
    /// outcome event.
    case transportDialStarted = 25
    /// A transport dial connected. Payload follows ``transportDialStarted``.
    case transportDialConnected = 26
    /// A transport dial failed. `a` is ``DiagnosticTransportKind``, `b` is
    /// ``DiagnosticFailureKind``, and `c` is the matching local attempt ID.
    case transportDialFailed = 27
    /// The remote host identity passed authenticated endpoint validation.
    case hostAuthenticated = 28
    /// The authenticated RPC session completed its readiness handshake.
    case rpcReady = 29
    /// Connection recovery started after a previously usable session degraded.
    case recoveryStarted = 30
    /// Connection recovery restored a usable session.
    case recoverySucceeded = 31
    /// Connection recovery exhausted its current attempt. `b`, when present,
    /// is ``DiagnosticFailureKind``.
    case recoveryFailed = 32
    /// The local Iroh endpoint started initialization.
    case endpointStarting = 33
    /// The local Iroh endpoint became active.
    case endpointActive = 34
    /// The local Iroh endpoint stopped.
    case endpointStopped = 35
    /// The local Iroh endpoint failed to start or remain active. `b`, when
    /// present, is ``DiagnosticFailureKind``.
    case endpointFailed = 36
    /// A signed relay-policy refresh started.
    case relayPolicyRefreshStarted = 37
    /// A signed relay policy was validated and installed.
    case relayPolicyRefreshSucceeded = 38
    /// A relay-policy refresh failed. `b`, when present, is
    /// ``DiagnosticFailureKind``.
    case relayPolicyRefreshFailed = 39
    /// The selected network path changed. `a` is ``DiagnosticPathKind``. The
    /// foreground control session wins over background and feature sessions.
    case selectedPathChanged = 40
    /// An established app-transport session closed. `a`, when present, is
    /// ``DiagnosticTransportKind``; `b`, when present, is
    /// ``DiagnosticFailureKind``; and `c`, when present, is the positive,
    /// process-local session ID shared with ``transportSessionLifecycle``.
    /// Absence of `b`, or `.none`, means an expected closure.
    case sessionClosed = 41
    /// No authenticated route was usable. `b`, when present, is
    /// ``DiagnosticFailureKind``.
    case routeUnavailable = 42
    /// A bounded retry was scheduled. `ms` is the delay before retry.
    case retryScheduled = 43
    /// Same-account or local-route discovery started.
    case discoveryStarted = 44
    /// Discovery produced at least one authenticated candidate.
    case discoverySucceeded = 45
    /// Discovery failed to produce an authenticated candidate. `b`, when
    /// present, is ``DiagnosticFailureKind``.
    case discoveryFailed = 46
    /// The host admitted the authenticated client to an RPC session.
    case admissionSucceeded = 47
    /// Host admission rejected or failed. `b`, when present, is
    /// ``DiagnosticFailureKind``.
    case admissionFailed = 48
    /// The remote host identity or secure channel failed authentication. `b`,
    /// when present, is ``DiagnosticFailureKind``.
    case hostAuthenticationFailed = 49
    /// The authenticated RPC session failed before or after readiness. `b`,
    /// when present, is ``DiagnosticFailureKind``.
    case rpcFailed = 50
    /// An admitted transport session was established or removed from its local
    /// pool. `a` is ``DiagnosticSessionLifecycleKind``, `b` is the local
    /// ``CmxTransportSessionPurpose`` raw value, and `c` is a positive,
    /// process-local session correlation ID. The event contains no peer or route
    /// identity.
    case transportSessionLifecycle = 51
}
