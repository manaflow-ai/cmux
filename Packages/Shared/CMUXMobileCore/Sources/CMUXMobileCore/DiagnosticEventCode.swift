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
    /// Pairing / attach failed. `a`, when present, is
    /// ``DiagnosticTransportKind``; `b`, when present, is
    /// ``DiagnosticFailureKind``.
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
    /// The local peer endpoint started initialization.
    case endpointStarting = 33
    /// The local peer endpoint became active.
    case endpointActive = 34
    /// The local peer endpoint stopped.
    case endpointStopped = 35
    /// The local peer endpoint failed to start or remain active. `b`, when
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
    /// Same-account or local-route discovery started. `a` is
    /// ``DiagnosticTransportKind``.
    case discoveryStarted = 44
    /// Discovery produced an authoritative snapshot. `a` is
    /// ``DiagnosticTransportKind``, `b` is its binding count, `c` is its
    /// managed relay-fleet count, and `ms` is the fetch duration.
    case discoverySucceeded = 45
    /// Discovery failed to produce an authoritative snapshot. `a` is
    /// ``DiagnosticTransportKind``, `b`, when present, is
    /// ``DiagnosticFailureKind``, and `ms` is the fetch duration.
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
    /// The app's scene phase changed. `a` is ``DiagnosticAppLifecyclePhase``.
    /// Session drops that follow a backgrounding within seconds are suspension
    /// casualties, not network failures; this event makes that attributable.
    case appLifecycleChanged = 52
    /// Device reachability changed. `a` is 1 when a usable network path
    /// exists, else 0. Correlates drops with WiFi/cellular transitions.
    case reachabilityChanged = 53
    /// The transport boundary reported why a shared connection closed. `a` is
    /// the stable close-initiator kind (0 unknown, 1 local, 2 remote, 3 timed
    /// out), `b` is ``DiagnosticFailureKind``, `ms` is the application error
    /// code clamped to the nonnegative `Int32` range when parseable, and `c` is
    /// the matching positive, process-local session correlation ID.
    case transportCloseAttribution = 54
    /// One transport path opened, closed, became selected, or reported lag. `a` is
    /// the stable path-event kind (1 opened, 2 closed, 3 selected, 4 lagged),
    /// `b` is ``DiagnosticPathKind`` for the affected path, and `c` is the
    /// matching positive, process-local session correlation ID.
    case transportPathEvent = 55
    // MARK: Browser streaming and control

    /// A phone-driven browser stream session changed lifecycle state on the
    /// Mac. `a` is the stage (1 started, 2 replaced an existing session,
    /// 3 stopped, 4 first frame emitted), and `c` is the positive browser
    /// panel correlation ID derived from the panel UUID.
    case browserStreamLifecycle = 56
    /// Replayed phone input reached a streamed browser panel. `a` is the
    /// input kind (1 pointer, 2 key, 3 text, 4 suppressed no-editable
    /// backspace), `b` is the click count for pointers, 1 for keys, or the
    /// inserted character count for text, and `c` is the panel correlation ID.
    case browserInputReplayed = 57
    /// The streamed page's editable-focus state changed or a replayed click's
    /// focus assist resolved. `a` is 1 when an editable has focus (else 0),
    /// `b` is the focus-assist outcome (0 no editable at the point, 1 focus
    /// moved, 2 already focused, 3 beacon-reported transition), and `c` is
    /// the panel correlation ID.
    case browserEditableFocus = 58
    /// A phone-initiated `mobile.browser.create` request resolved on the Mac.
    /// `a` is 1 on success else 0, and `c` is the panel correlation ID of the
    /// created panel (absent on failure).
    case browserPanelCreateResolved = 59

    // MARK: Simulator streaming and control

    /// A phone-controlled Simulator stream lifecycle edge. `surface` is a
    /// process-local panel handle, `a` is
    /// ``DiagnosticSimulatorStreamLifecycle``, `b` is
    /// ``DiagnosticSimulatorOwnershipState``, and `c`, when present, is a
    /// bounded count such as the active session count.
    case simulatorStreamLifecycle = 60
    /// One frame-pipeline edge. `surface` is a process-local panel handle,
    /// `a` is ``DiagnosticSimulatorFrameLifecycle``, `b`, when present, is a
    /// clamped frame sequence number, and `c`, when present, is a byte count.
    case simulatorFrameLifecycle = 61
    /// One phone-originated Simulator input edge. `surface` is a process-local
    /// panel handle, `a` is ``DiagnosticSimulatorInputLifecycle``, `b` is
    /// ``DiagnosticSimulatorInputKind``, and `c`, when present, is a
    /// phase/button/text-size detail.
    case simulatorInputLifecycle = 62
    /// A phone touch point was mapped before dispatch. `surface` is a
    /// process-local panel handle, `a` and `b` are normalized x/y in
    /// ten-thousandths, and `c` is ``DiagnosticSimulatorCoordinateState``.
    case simulatorCoordinateMapped = 63
    /// A Simulator stream ownership descriptor changed. `surface` is a
    /// process-local panel handle, `a` is the new
    /// ``DiagnosticSimulatorOwnershipState``, and `b` is the previous state
    /// when known.
    case simulatorOwnershipChanged = 64

    // MARK: App-wide feature observability

    /// One privacy-safe iOS feature boundary event. `a` is
    /// ``DiagnosticAppEventKind``; `b`, when present, is a
    /// ``DiagnosticFailureKind``; `c`, when present, is a bounded count or
    /// magnitude documented by that event kind; `ms`, when present, is elapsed
    /// time; and `surface`, when present, is a process-local correlation handle.
    ///
    /// This is the app-wide vocabulary for user actions and feature outcomes
    /// that do not belong to the transport, browser-frame, or Simulator hot
    /// paths. Event kinds are fixed enums, never caller-provided strings, so the
    /// durable Release log cannot capture terminal contents, credentials,
    /// account identifiers, file paths, URLs, workspace titles, or error text.
    case appFeatureAction = 65

    // Raw values 66-70 are reserved for app-wide diagnostic expansion.

    // MARK: Peer dial bootstrap diagnostics

    /// One direct dial plan was assembled before any connect attempt. `a` is
    /// the public path hint count, `b` is the private fallback path hint
    /// count, and `c` is the public relay-URL hint count. A plan with both
    /// counts zero proves no dial packet was sent.
    case transportDialPlanBuilt = 71
    /// Configured private addresses were joined with the target Mac's
    /// broker-registered UDP port for one dial. `a` is the join state
    /// (``DiagnosticPrivateAddressJoinState``), `b` is the configured
    /// address count, and `c` is the resulting dialable hint count.
    case transportPrivateAddressJoin = 72
    /// Account-private LAN discovery resolved for one dial. `a` is the
    /// outcome (``DiagnosticLANDiscoveryOutcome``) and `b` is the resolved
    /// hint count.
    case transportLANDiscovery = 73
    /// One direct dial leg connected. `a` is the leg
    /// (``DiagnosticDirectDialLeg``).
    case transportDialLegSucceeded = 74
    /// One direct dial leg failed before a connection existed. `a` is the
    /// leg (``DiagnosticDirectDialLeg``) and `b` is the classified
    /// ``DiagnosticFailureKind``.
    case transportDialLegFailed = 75
    /// The Mac's account-private LAN advertisement changed publication
    /// state. `a` is the state (``DiagnosticLANPublicationState``) and `b`
    /// is the synchronization reason (0 applied, 1 listener setting
    /// disabled, 2 runtime context unavailable).
    case lanPublicationState = 76

    /// The transport dial was associated with the admitted session it opened.
    /// `surface` is the process-local peer alias, `a` is the dial attempt ID,
    /// and `c` is the matching session ID.
    case transportDialSessionLinked = 77
    /// A pending dial was cancelled by a lifecycle owner. `surface` is the
    /// peer alias, `a` is ``DiagnosticCancellationReason``, `ms` is elapsed
    /// dial time, and `c` is the dial attempt ID.
    case transportDialCancelled = 78
    /// A close carried a bounded remote reason token. `surface` is the peer
    /// alias, `a` is ``DiagnosticRemoteCloseReason``, and `c` is the session ID.
    case transportCloseReason = 79
}

/// Scene phase carried by ``DiagnosticEventCode/appLifecycleChanged``.
public enum DiagnosticAppLifecyclePhase: Int, Sendable, Codable, CaseIterable {
    case background = 0
    case active = 1
    case inactive = 2
}

public extension DiagnosticEventCode {
    /// Whether this event belongs to the Simulator streaming/control feature.
    var isSimulatorDiagnosticEvent: Bool {
        switch self {
        case .simulatorStreamLifecycle,
             .simulatorFrameLifecycle,
             .simulatorInputLifecycle,
             .simulatorCoordinateMapped,
             .simulatorOwnershipChanged:
            true
        default:
            false
        }
    }

    /// Whether this event belongs to app-wide iOS feature observability rather
    /// than the network or frame-stream planes.
    var isAppFeatureDiagnosticEvent: Bool {
        self == .appFeatureAction
    }
}
