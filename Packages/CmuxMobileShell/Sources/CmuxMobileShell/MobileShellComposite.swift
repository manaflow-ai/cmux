public import CMUXMobileCore
internal import CmuxMobileDiagnostics
public import CmuxMobilePairedMac
public import CmuxMobileRPC
public import CmuxMobileShellModel
internal import CmuxMobileSupport
public import CmuxMobileTransport
public import Foundation
import Observation
internal import OSLog

private let mobileShellLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

/// Transitional alias for the decomposed shell facade.
///
/// The iOS views and push coordinator still bind to `CMUXMobileShellStore`;
/// this keeps those call sites compiling while the god store is dissolved into
/// composed coordinators behind ``MobileShellComposite``. Remove once every
/// consumer binds to ``MobileShellComposite`` directly.
public typealias CMUXMobileShellStore = MobileShellComposite

/// The decomposed home object the iOS shell views bind to.
///
/// Holds the connection lifecycle, network-recovery state machine,
/// workspace/terminal list state, and the render-grid-vs-raw-bytes terminal
/// output pipeline behind one `@Observable` read surface. Constructed at the
/// app composition root with its collaborators injected as protocol seams
/// (``MobileSyncRuntime``, ``MobilePairedMacStoring``, ``MobileIdentityProviding``,
/// ``ReachabilityProviding``, ``MobileClientIDRepository``).
@MainActor
@Observable
public final class MobileShellComposite: MobileTerminalOutputSinking {
    private enum TerminalOutputTransport: Equatable {
        case renderGrid
        case rawBytes

        var eventTopics: [String] {
            switch self {
            case .renderGrid:
                return ["workspace.updated", "terminal.render_grid", "notification.dismissed", "notification.badge"]
            case .rawBytes:
                return ["workspace.updated", "terminal.bytes", "notification.dismissed", "notification.badge"]
            }
        }
    }

    private static let hasKnownPairedMacDefaultsKey = "cmux.mobile.hasKnownPairedMac"

    /// Max seconds the launch reconnect may keep the restoring gate
    /// (``RestoringSessionView``) on screen before resolving to the
    /// disconnected/add-device UI. A stored Mac whose route went stale makes the
    /// connect hang on a slow timeout; this caps the visible "Restoring session…"
    /// window so a returning user is never stuck on it. The connect keeps trying
    /// in the background, so a later success still flips to the workspaces.
    private static let storedMacReconnectRestoringDeadlineSeconds: Double = 6

    private static let terminalRenderGridCapability = "terminal.render_grid.v1"
    private static let workspaceActionsCapability = "workspace.actions.v1"
    private static let workspaceReadStateCapability = "workspace.read_state.v1"
    private static let workspaceCloseCapability = "workspace.close.v1"
    private static let dogfoodFeedbackCapability = "dogfood.v1"
    private static let workspaceGroupsCapability = "workspace.groups.v1"
    private static let terminalOutputCapabilityTimeoutNanoseconds: UInt64 = 750_000_000

    /// How long the render-grid stream may stay silent (no event of any topic)
    /// before the liveness watchdog suspects the push subscription is dead and
    /// runs a bounded host probe; only a failed probe forces the
    /// re-subscribe + replay (silence alone is the normal state of an idle
    /// terminal). Picked at the low end of the acceptable 8-12s window so a
    /// wedged stream recovers in a few seconds instead of the transport's ~85s
    /// timeout, while staying well above any normal inter-event gap on a busy
    /// shell.
    private static let renderGridLivenessSilenceThreshold: TimeInterval = 9
    /// Cadence of the liveness watchdog tick. It only reads a timestamp and
    /// compares against the threshold, so a short interval is cheap; it does not
    /// reschedule per received event (an actively-streaming connection just keeps
    /// failing the silence check because `lastTerminalEventAt` stays fresh).
    private static let renderGridLivenessCheckInterval: TimeInterval = 2.5

    public private(set) var isSignedIn: Bool {
        didSet {
            guard oldValue != isSignedIn else { return }
            // Presence follows the session: subscribe while signed in, tear
            // down (and blank the map) the moment the user signs out so a
            // shared device never renders the previous account's devices.
            evaluatePresenceSubscription()
        }
    }
    public private(set) var connectionState: MobileConnectionState {
        didSet {
            // Collapse the ~15 `connectionState = .disconnected/.connected` sites
            // into one analytics edge: emit at most one `ios_connection_lost` per
            // outage and one `ios_connection_recovered` per recovery. `didSet`
            // does not fire for the in-init assignment, so this only observes
            // real transitions. The throttle's `outageOpen` is the per-outage gate.
            guard oldValue != connectionState else { return }
            // Intentional teardown (sign-out, forget, switch) must not look like
            // a network outage: swallow this edge and reset the throttle so a
            // later real reconnect doesn't emit `recovered` with a bogus duration.
            if suppressNextConnectionOutageEdge {
                suppressNextConnectionOutageEdge = false
                connectionOutageThrottle = ConnectionOutageThrottle()
                connectionOutageStartedAt = nil
                return
            }
            let transition = ConnectionOutageThrottle.Transition(
                wasConnected: oldValue == .connected,
                isConnected: connectionState == .connected
            )
            switch connectionOutageThrottle.record(transition: transition) {
            case .lost:
                connectionOutageStartedAt = runtime?.now() ?? Date()
                analytics.capture("ios_connection_lost", [
                    "was_active": .bool(activeTicket != nil),
                ])
            case .recovered:
                var props: [String: AnalyticsValue] = [:]
                if let startedAt = connectionOutageStartedAt {
                    let outageMs = Int(((runtime?.now() ?? Date()).timeIntervalSince(startedAt)) * 1000)
                    props["outage_duration_ms"] = .int(max(0, outageMs))
                }
                connectionOutageStartedAt = nil
                analytics.capture("ios_connection_recovered", props)
            case .none:
                break
            }
        }
    }
    public private(set) var macConnectionStatus: MobileMacConnectionStatus
    public private(set) var connectedHostName: String
    public private(set) var connectionError: String?
    /// Actionable next-step line shown beneath ``connectionError`` (for example
    /// "Check that both devices are on the same Tailscale"). Set and cleared
    /// together with the error by the pairing-failure classifier sink.
    public private(set) var connectionErrorGuidance: String?
    /// A warning that must be accepted before pairing continues, currently used
    /// for Mac/iPhone app-version skew.
    public private(set) var pairingVersionWarning: String?
    public private(set) var activeTicket: CmxAttachTicket?
    public private(set) var activeRoute: CmxAttachRoute?

    /// True only while an actually-found stored Mac is mid-reconnect.
    ///
    /// Set just before awaiting the connect for a Mac resolved from the paired-Mac
    /// store on launch (or network recovery), and cleared once that attempt
    /// resolves. Drives the root scene's choice to show ``RestoringSessionView``
    /// during the reconnect window instead of the empty add-device sheet.
    public private(set) var isReconnectingStoredMac: Bool = false

    /// True once the first launch reconnect attempt has resolved.
    ///
    /// A failed or offline reconnect sets this so the root scene falls through to
    /// the disconnected/add-device view instead of spinning on
    /// ``RestoringSessionView`` forever.
    public private(set) var didFinishStoredMacReconnectAttempt: Bool = false

    /// Persisted hint that this device has previously paired a Mac.
    ///
    /// Read synchronously at init from the injected `UserDefaults` so the very
    /// first rendered frame can show ``RestoringSessionView`` for a returning user
    /// before the async paired-Mac read runs. Writes persist through to the same
    /// defaults via the property's `didSet`.
    public private(set) var hasKnownPairedMac: Bool {
        didSet {
            pairingHintDefaults.set(hasKnownPairedMac, forKey: Self.hasKnownPairedMacDefaultsKey)
            // Writing the hint resolves the "undetermined" upgrade window.
            pairedMacHintUndetermined = false
        }
    }

    /// Whether the persisted paired-Mac hint has never been written on this
    /// install (the key was absent at launch). True only for installs that
    /// predate ``hasKnownPairedMac`` — those users may already have an active Mac
    /// in the paired-Mac store, so the restoring gate treats "undetermined" like
    /// "may have a paired Mac" until the first reconnect attempt resolves and
    /// writes the hint. Cleared the moment ``hasKnownPairedMac`` is written.
    public private(set) var pairedMacHintUndetermined: Bool

    /// Monotonically-increasing token identifying the latest stored-Mac reconnect
    /// attempt. Overlapping reconnects (multiple launch paths, network recovery,
    /// sign-out, forget) each claim a generation; only the current generation may
    /// resolve the restoring-gate flags, so a superseded older attempt can't clear
    /// the gate while a newer reconnect is still in progress.
    private var storedMacReconnectGeneration = 0
    public var hasActiveUnexpiredAttachTicket: Bool {
        guard let activeTicket,
              activeTicket.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        return Self.attachTicketIsUnexpired(activeTicket, now: runtime?.now() ?? Date())
    }
    public var pairingCode: String
    public var workspaces: [MobileWorkspacePreview] {
        didSet { workspaceTopologyVersion &+= 1 }
    }
    /// Bumped on every ``workspaces`` mutation: a cheap "lists may have
    /// changed" signal (e.g. for retrying a parked notification deep link).
    public private(set) var workspaceTopologyVersion: UInt64 = 0
    /// The Mac's workspace groups, in section order. Empty when the Mac reports no
    /// groups (or is old enough not to emit them). Drives the collapsible group
    /// sections in the workspace list.
    public var workspaceGroups: [MobileWorkspaceGroupPreview] = []
    /// The connected Mac's `mobile.host.status` capabilities. Feature gates are
    /// computed from this set so version-skew checks cannot drift from the raw
    /// host payload.
    public private(set) var supportedHostCapabilities: Set<String> = []
    /// Whether the Mac supports workspace group sections and collapse/expand RPCs.
    public var supportsWorkspaceGroups: Bool { supportedHostCapabilities.contains(Self.workspaceGroupsCapability) }
    /// Whether the Mac supports rename/pin workspace actions.
    public var supportsWorkspaceActions: Bool { supportedHostCapabilities.contains(Self.workspaceActionsCapability) }
    /// Whether the Mac supports mark read/unread workspace actions.
    public var supportsWorkspaceReadStateActions: Bool { supportedHostCapabilities.contains(Self.workspaceReadStateCapability) }
    /// Whether the Mac supports workspace close requests.
    public var supportsWorkspaceCloseActions: Bool { supportedHostCapabilities.contains(Self.workspaceCloseCapability) }
    /// Whether the Mac supports dogfood feedback submission.
    public var supportsDogfoodFeedback: Bool { supportedHostCapabilities.contains(Self.dogfoodFeedbackCapability) }
    /// The composer's live draft for the currently selected terminal.
    ///
    /// Edits are persisted per-terminal through the FIFO draft pipeline on every
    /// change (see `didSet`), so the draft survives terminal switches; loads set
    /// `isLoadingDraft` so the restore is not re-saved under the wrong terminal
    /// key.
    public var terminalInputText: String {
        didSet {
            #if DEBUG
            // COMPOSER: record every draft change so a captured trace shows whether
            // the draft was cleared at the store (b == 1) during a keyboard-dismiss
            // cycle, vs. only disappearing from the view. `didSet` does not fire on
            // the `init` assignment, so this is safe to read `diagnosticLog`.
            diagnosticLog?.record(DiagnosticEvent(
                .composerInputTextChanged,
                a: terminalInputText.utf8.count,
                b: terminalInputText.isEmpty ? 1 : 0
            ))
            #endif
            // Persist the live edit under the CURRENT terminal so it survives a
            // terminal switch. Skipped while a draft is being loaded (the load is
            // the saved value, re-saving it is redundant and would race the
            // per-terminal key swap) and when the value is unchanged.
            guard !isLoadingDraft, terminalInputText != oldValue else { return }
            // A user edit claims field ownership for the selected terminal: the
            // live input is now authoritative, so a still-in-flight stored-draft
            // load must not apply over it (see ``applyLoadedDraft``).
            draftLoadPendingTerminalID = nil
            persistCurrentDraft()
        }
    }
    /// Whether the iMessage-style composer is shown above the terminal, observed
    /// by the terminal screen to present ``terminalInputText`` for multi-line
    /// editing.
    ///
    /// OPEN BY DEFAULT per terminal: like iMessage showing its input bar in every
    /// conversation, the composer is presented for any selected terminal the user
    /// has not explicitly dismissed (``composerDismissedTerminalIDs`` records the
    /// exception, not the rule). Presented does NOT mean focused — the keyboard
    /// comes up only when the user taps the field or an explicit open/reveal
    /// requests focus (``composerFocusRequest``). Derived from observable stored
    /// state (`selectedTerminalID` + the dismissed set), so views tracking it
    /// re-render on terminal switches and explicit toggles alike.
    public var isComposerPresented: Bool {
        guard let terminalID = selectedTerminalID?.rawValue else { return false }
        return !composerDismissedTerminalIDs.contains(terminalID)
    }
    /// Terminal IDs whose composer the user explicitly dismissed (the band's
    /// chevron, or a genuine close from the compose button). Session-only: a
    /// relaunch returns every terminal to the default-open composer. Stored (not
    /// `@ObservationIgnored`) so ``isComposerPresented`` is observable through it.
    private var composerDismissedTerminalIDs: Set<String> = []
    /// Monotonic focus-request token for the iMessage-style composer field.
    ///
    /// The composer's text field owns its first responder via SwiftUI `@FocusState`,
    /// which neither the terminal surface nor the representable coordinator can set
    /// directly. When the surface needs the field re-focused without re-presenting the
    /// composer — the reveal-after-hide case, where the chrome and draft are already
    /// back but the terminal proxy stole first responder — it bumps this token through
    /// ``presentAndFocusComposer()``. ``TerminalComposerView`` observes the change and
    /// drives `isFieldFocused = true`, keeping `@FocusState` the single source of truth
    /// for who holds the keyboard.
    public private(set) var composerFocusRequest: Int = 0
    /// True while a ``composerFocusRequest`` has been issued but not yet consumed
    /// by the composer field. The field's `onChange` of the token only observes
    /// bumps that happen while the view is mounted; an explicit open (or a
    /// terminal switch while composing) bumps the token BEFORE the new composer
    /// view mounts, so the view's `onAppear` consumes this flag instead
    /// (``consumePendingComposerFocusRequest(for:)``). Default-open presentations
    /// never set it, which is exactly what keeps the keyboard down for them.
    /// Not observed: a handshake with the field, not view state.
    @ObservationIgnored private var composerFocusRequestPending = false
    /// The terminal the pending ``composerFocusRequest`` targets (the selected
    /// terminal at the moment the request was issued). Consumption is keyed on
    /// it: during a terminal switch the OUTGOING composer view is still mounted
    /// and observes the same token, so an unkeyed pending bit could be consumed
    /// by the dying view and the incoming terminal's field would never focus.
    @ObservationIgnored private var composerFocusRequestTerminalID: String?
    /// Whether the composer's text field currently holds first responder,
    /// mirrored from the view's `@FocusState` via
    /// ``composerFieldFocusChanged(_:)``. Read on terminal switches to decide
    /// whether the incoming terminal's composer should re-take focus (keeping the
    /// keyboard up across a switch mid-compose) — without it, every switch would
    /// either pop the keyboard (always refocus) or drop it (never refocus).
    /// Cleared explicitly on dismiss because the unmounting field does not
    /// reliably deliver its final unfocus change. Not observed: bookkeeping for
    /// the switch decision, not view state.
    @ObservationIgnored private var composerFieldIsFocused = false
    /// Guards ``submitComposerInput()`` against re-entrancy. A quick double tap
    /// on Send would otherwise start two sends that both capture the same text
    /// (the field is cleared only on ack), pasting the message to the agent
    /// twice. Not observed: it gates an async flow, not view state.
    @ObservationIgnored private var isSubmittingComposerInput = false
    public var selectedWorkspaceID: MobileWorkspacePreview.ID? {
        didSet {
            syncSelectedTerminalForWorkspace()
        }
    }
    /// The terminal whose surface (and composer draft) is currently shown.
    ///
    /// Changing it swaps the composer draft: `willSet` captures the outgoing
    /// terminal's draft before the id lands, `didSet` persists it under the old
    /// key and loads the incoming terminal's saved draft.
    public var selectedTerminalID: MobileTerminalPreview.ID? {
        willSet {
            // Capture the draft of the terminal we are leaving BEFORE the new id
            // lands, so `swapDraft(from:to:)` can persist it under the correct
            // (old) key. A no-op when the id is unchanged.
            guard newValue != selectedTerminalID else { return }
            draftedOutgoingTerminalID = selectedTerminalID
            draftedOutgoingText = terminalInputText
        }
        didSet {
            guard selectedTerminalID != oldValue else { return }
            swapDraft(from: draftedOutgoingTerminalID, outgoingText: draftedOutgoingText, to: selectedTerminalID)
            draftedOutgoingTerminalID = nil
            draftedOutgoingText = ""
            // Switching terminals rebuilds the surface (and the composer view with
            // it). When the user was actively composing — the field held first
            // responder at the moment of the switch — ask the incoming terminal's
            // composer to re-take focus so the keyboard hands over in place
            // instead of dropping. A default-open-but-unfocused composer issues no
            // request, so a mere switch never pops the keyboard.
            if composerFieldIsFocused, isComposerPresented {
                requestComposerFieldFocus()
            } else {
                // Any switch that does not arm a new handshake invalidates a
                // stale unconsumed one, so a plain switch back to a terminal
                // can never pop the keyboard off an old request.
                composerFocusRequestPending = false
                composerFocusRequestTerminalID = nil
            }
        }
    }

    /// The per-terminal composer-draft seam. `nil` in previews/tests that do not
    /// exercise drafts; every draft hook is then a no-op and the in-memory
    /// ``terminalInputText`` behaves exactly as before. Injected from the app
    /// composition root.
    private let draftStore: (any TerminalDraftStoring)?

    /// True while a saved draft is being loaded INTO ``terminalInputText``, so
    /// its `didSet` does not immediately re-save the just-loaded value (which
    /// would also race the key swap). Not observed: it gates a write, not view
    /// state.
    @ObservationIgnored private var isLoadingDraft = false
    /// Tail of the FIFO draft pipeline (see ``enqueueDraftOperation(_:)``).
    /// Every draft-store operation chains onto this so store effects apply in
    /// exactly the order they were issued from the main actor. Not observed: it
    /// sequences async work, not view state.
    @ObservationIgnored private var draftOperationTail: Task<Void, Never>?
    /// Latest unflushed keystroke draft per terminal (see
    /// ``persistCurrentDraft()``). Keystroke saves coalesce here: each edit
    /// overwrites the terminal's entry and at most ONE flush task per terminal
    /// is queued on the pipeline, reading the entry at execution time. A typing
    /// burst behind a slow store therefore retains one latest snapshot per
    /// terminal instead of one snapshot per edit. Not observed: it buffers
    /// writes, not view state.
    @ObservationIgnored private var pendingDraftSaveTextByTerminalID: [String: String] = [:]
    /// The terminal id we are switching away from, captured in
    /// ``selectedTerminalID``'s `willSet` so its draft is saved under the right key.
    @ObservationIgnored private var draftedOutgoingTerminalID: MobileTerminalPreview.ID?
    /// The draft text of the terminal we are switching away from, captured with
    /// ``draftedOutgoingTerminalID``.
    @ObservationIgnored private var draftedOutgoingText: String = ""
    /// The terminal whose stored-draft load is still in flight while the field
    /// shows the transient cleared placeholder. While this matches a terminal,
    /// the visible field does NOT represent that terminal's draft yet, so a
    /// switch away from it must not persist the placeholder over its real
    /// stored draft (the fast A -> B -> C switch erased B's untouched draft).
    /// Consumed when the load applies; cleared by a user edit, which claims
    /// field ownership for the selected terminal (live input wins over a late
    /// load, so deleted text cannot resurrect). Not observed: bookkeeping, not
    /// view state.
    @ObservationIgnored private var draftLoadPendingTerminalID: MobileTerminalPreview.ID?

    /// Surface IDs whose next window attach must NOT grab the keyboard.
    ///
    /// A surface in this set mounts with autofocus disabled; the entry is
    /// cleared once that surface has appeared and consumed the suppression
    /// (``consumeTerminalAutoFocusSuppression(for:)``). Ownership lives here,
    /// next to selection and terminal creation, rather than in the view, so the
    /// create path can mark the *exact* new terminal id the instant it becomes
    /// the selection. A freshly created terminal therefore never steals the
    /// keyboard, while push-notification navigation (``selectTerminal(_:)``) is
    /// intentionally left out of the set and allowed to autofocus.
    private var terminalAutoFocusSuppressedSurfaceIDs: Set<String> = []

    private let runtime: (any MobileSyncRuntime)?
    private let pairedMacStore: (any MobilePairedMacStoring)?
    /// Best-effort, team-scoped lookup of fresher attach routes from the device
    /// registry. Optional and failure-tolerant: when `nil` or unreachable,
    /// reconnect uses the locally persisted paired-Mac routes, so pairing
    /// survives the cloud registry being down.
    private let deviceRegistry: (any DeviceRegistryRefreshing)?
    /// Live presence subscription (the `workers/presence` Durable Object edge).
    /// Optional and failure-tolerant like the registry: when `nil` or down, the
    /// device tree simply keeps its registry "last seen" hints.
    private let presence: (any PresenceSubscribing)?
    private let identityProvider: (any MobileIdentityProviding)?
    private let reachability: any ReachabilityProviding
    // Internal (not private): used by the dismiss-sync extension file.
    let deliveredNotificationClearer: any DeliveredNotificationClearing
    /// Durable outbox for phone→Mac dismissals.
    let pendingDismissQueue: PendingNotificationDismissQueue
    private let pairingHintDefaults: UserDefaults
    let clientID: String
    /// Delivers the email path of Send Feedback (`/api/feedback`). `nil` when the
    /// web API base URL is unavailable; the email path then fails closed and the
    /// UI surfaces an error rather than silently dropping the report.
    private let feedbackEmailSubmitter: (any MobileFeedbackEmailSubmitting)?
    /// Resolves the current build + device stamp. Injected from the app layer
    /// (which can read `Bundle.main`/`UIDevice`); defaults to an empty stamp so
    /// previews/tests need not provide one.
    private let feedbackStampProvider: @MainActor () -> MobileFeedbackStamp
    /// The injected, fire-and-forget product-analytics emitter. Defaults to
    /// ``NoopAnalytics`` so previews/tests inject nothing.
    private let analytics: any AnalyticsEmitting
    /// Collapses connection-state edges into one-per-outage lost/recovered events.
    private var connectionOutageThrottle = ConnectionOutageThrottle()
    /// When the current outage began, for the recovered event's duration.
    private var connectionOutageStartedAt: Date?
    /// Set just before an intentional teardown drops `connectionState`, so the
    /// `didSet` swallows that edge instead of emitting a false `ios_connection_lost`.
    private var suppressNextConnectionOutageEdge = false
    /// When the in-flight pairing attempt began, for `*_succeeded`/`_failed`
    /// `duration_ms`. Keyed implicitly by ``pairingAttemptID``.
    private var pairingAttemptStartedAt: Date?
    /// The method (`qr`/`manual`/`attach_url`) of the in-flight pairing attempt.
    private var pairingAttemptMethod: String?
    /// Whether this install had no known paired Mac at the *start* of the in-flight
    /// attempt. Snapshotted in ``beginPairingAttempt(method:)`` and reused for the
    /// started/succeeded/failed events, because a successful `connect(ticket:)`
    /// sets ``hasKnownPairedMac`` to `true` before `succeeded` is recorded — so
    /// reading it again would report the first successful pair as `is_first_pair:
    /// false` and break the first-pair funnel.
    private var pairingAttemptIsFirstPair = false
    private var pendingPairingVersionWarningURL: String?

    /// The structured diagnostic log, injected from the app composition root.
    ///
    /// Recording is lock-free and `nonisolated`, so the connect/pair, liveness,
    /// and seq/byte-gap seams below dual-emit a compact ``DiagnosticEvent``
    /// alongside their existing ``MobileDebugLog/anchormux(_:)`` string line.
    /// `nil` in previews/tests that do not exercise the round-trip. Exposed
    /// `public` so the DEV feedback-submit affordance can ``DiagnosticLog/export()``
    /// it.
    public let diagnosticLog: DiagnosticLog?
    var remoteClient: MobileCoreRPCClient? {
        didSet {
            if remoteClient == nil {
                stopTerminalRefreshPolling()
                cancelRemoteOperationTasks()
                resetTerminalOutputTracking()
            }
        }
    }
    private var terminalEventListenerTask: Task<Void, Never>?
    private var terminalEventListenerID: UUID?
    /// Recovers the Mac's identity post-handshake for tickets that arrived
    /// without one (the minimal v2 pairing QR). Owned separately from the
    /// short capability probe; see ``scheduleHostIdentityAdoptionIfNeeded(client:)``.
    /// Cancelled on disconnect via ``cancelRemoteOperationTasks()``.
    private var hostIdentityAdoptionTask: Task<Void, Never>?
    /// Tail of the serialized paired-Mac store write chain; see
    /// ``performSerializedPairedMacWrite(ifStillCurrent:_:)``.
    private var pairedMacWriteChain: Task<Void, Never>?
    /// The in-flight `mobile.events.subscribe` (reason `start`) ack for the
    /// current listener generation. It runs concurrently with the consumer
    /// loop (the ack is a server-side enable handshake, not a delivery
    /// precondition: a prior generation's server subscription keeps pushing
    /// across re-subscribes) so events arriving during the round-trip are
    /// consumed, not buffered invisibly behind the await.
    private var terminalSubscriptionStartTask: Task<Void, Never>?
    // Liveness watchdog for the render-grid push subscription. The `for await`
    // listener loop blocks indefinitely if the underlying connection half-dies
    // (network blip, Mac stops pushing, background/foreground cycle): the
    // AsyncStream neither yields a new event nor finishes, so the loop sits
    // silent and the phone shows a stale frame while the Mac advances thousands
    // of render-grid deltas. The transport's own timeout (~85s) is far too slow.
    // A `DispatchSourceTimer` ticks independently of the (potentially wedged)
    // stream and compares "now" against the last received event to detect
    // prolonged silence. Silence alone is NOT death: a healthy idle terminal
    // pushes nothing (the Mac dedupes unchanged render-grid frames), so a
    // silence-threshold crossing first runs a bounded idempotent
    // `mobile.events.subscribe` probe (same stream id, current topics) and
    // only tears down + re-subscribes + replays when the host fails to answer
    // it.
    private var renderGridLivenessTimer: (any DispatchSourceTimer)?
    private var renderGridLivenessListenerID: UUID?
    /// The in-flight liveness probe spawned by a silence-threshold crossing.
    /// Single-flight: ticks while a probe is pending are no-ops. The paired
    /// `renderGridLivenessProbeID` is the slot's ownership token: only the
    /// probe holding it may clear the slot, so a cancelled probe from an older
    /// generation completing late cannot free or clobber a newer generation's
    /// in-flight slot.
    private var renderGridLivenessProbeTask: Task<Void, Never>?
    private var renderGridLivenessProbeID: UUID?
    private var lastTerminalEventAt: Date?
    private var terminalSubscriptionRefreshTask: Task<Void, Never>?
    private var createWorkspaceTask: Task<Void, Never>?
    private var createTerminalTask: Task<Void, Never>?
    private var workspaceListRefreshTask: Task<Void, Never>?
    /// The user pull-to-refresh round-trip, kept on its own handle so the
    /// event-driven ``workspaceListRefreshTask`` cancel/restart can never truncate
    /// the spinner the pull is awaiting. Rapid pulls coalesce onto this single task.
    private var pullToRefreshTask: Task<Void, Never>?
    private var createWorkspaceTaskID: UUID?
    private var createTerminalTaskID: UUID?
    private var connectionGeneration: UUID
    private var connectionAttemptGeneration: UUID
    private var reportedViewportSizesByTerminalKey: [MobileTerminalViewportKey: MobileTerminalViewportSize]
    private var deliveredTerminalByteEndSeqBySurfaceID: [String: UInt64]
    private var pendingTerminalByteEndSeqBySurfaceID: [String: UInt64]
    private var terminalReplaySurfaceIDsInFlight: Set<String>
    private var terminalOutputTransport: TerminalOutputTransport
    var terminalByteContinuationsBySurfaceID: [String: AsyncStream<MobileTerminalOutputChunk>.Continuation]
    var terminalOutputStreamTokensBySurfaceID: [String: UUID]
    var terminalOutputQueuesBySurfaceID: [String: TerminalOutputDeliveryQueue]
    var terminalScrollQueueTokensBySurfaceID: [String: UUID]
    var terminalScrollQueuesBySurfaceID: [String: TerminalScrollDeliveryQueue]
    var terminalScrollbackPrefetchStatesBySurfaceID: [String: TerminalScrollbackPrefetchState]
    private var rawTerminalInputBuffer: MobileTerminalInputSendBuffer
    private var pairingAttemptID: UUID

    public var phase: MobileShellPhase {
        if !isSignedIn {
            return .signIn
        }
        if connectionState != .connected {
            return .pairing
        }
        return .workspaces
    }

    public var selectedWorkspace: MobileWorkspacePreview? {
        guard let selectedWorkspaceID else {
            return workspaces.first
        }
        return workspaces.first { $0.id == selectedWorkspaceID } ?? workspaces.first
    }

    private var selectedTerminal: MobileTerminalPreview? {
        guard let selectedWorkspace else {
            return nil
        }
        if let selectedTerminalID,
           let terminal = selectedWorkspace.terminals.first(where: { $0.id == selectedTerminalID }) {
            return terminal
        }
        return selectedWorkspace.preferredTerminal
    }

    /// A small stable numeric handle for a surface-id string, for the compact
    /// ``DiagnosticEvent/surface`` field. Surface ids are strings (e.g.
    /// `"workspace-1-terminal-2"`); this maps one to a `UInt32` so the structured
    /// log can carry which surface an event relates to without storing a string.
    /// Correlation only, not reversible.
    private static func diagnosticSurfaceHandle(_ surfaceID: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in surfaceID.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return hash
    }

    public init(
        runtime: (any MobileSyncRuntime)? = nil,
        isSignedIn: Bool = false,
        connectionState: MobileConnectionState = .disconnected,
        connectedHostName: String = "",
        pairingCode: String = "",
        workspaces: [MobileWorkspacePreview] = [],
        pairedMacStore: (any MobilePairedMacStoring)? = nil,
        deviceRegistry: (any DeviceRegistryRefreshing)? = nil,
        presence: (any PresenceSubscribing)? = nil,
        clientIDRepository: MobileClientIDRepository = MobileClientIDRepository(defaults: .standard),
        identityProvider: (any MobileIdentityProviding)? = nil,
        reachability: any ReachabilityProviding = ReachabilityService(),
        deliveredNotificationClearer: any DeliveredNotificationClearing = SystemDeliveredNotificationClearer(),
        pendingDismissQueue: PendingNotificationDismissQueue = PendingNotificationDismissQueue(),
        pairingHintDefaults: UserDefaults = .standard,
        analytics: any AnalyticsEmitting = NoopAnalytics(),
        diagnosticLog: DiagnosticLog? = nil,
        feedbackEmailSubmitter: (any MobileFeedbackEmailSubmitting)? = nil,
        feedbackStampProvider: @escaping @MainActor () -> MobileFeedbackStamp = { MobileShellComposite.emptyFeedbackStamp },
        draftStore: (any TerminalDraftStoring)? = nil
    ) {
        self.runtime = runtime
        self.draftStore = draftStore
        self.pairedMacStore = pairedMacStore
        self.deviceRegistry = deviceRegistry
        self.presence = presence
        self.identityProvider = identityProvider
        self.reachability = reachability
        self.deliveredNotificationClearer = deliveredNotificationClearer
        self.pendingDismissQueue = pendingDismissQueue
        self.pairingHintDefaults = pairingHintDefaults
        self.analytics = analytics
        self.diagnosticLog = diagnosticLog
        self.feedbackEmailSubmitter = feedbackEmailSubmitter
        self.feedbackStampProvider = feedbackStampProvider
        // Distinguish "key absent" (an install that predates the hint and may
        // already have a paired Mac in SQLite) from "key present and false" (we
        // determined there is no paired Mac). didSet is not called for these
        // initial assignments, so the undetermined flag is not clobbered here.
        self.pairedMacHintUndetermined = pairingHintDefaults.object(forKey: Self.hasKnownPairedMacDefaultsKey) == nil
        self.hasKnownPairedMac = pairingHintDefaults.bool(forKey: Self.hasKnownPairedMacDefaultsKey)
        // The id is resolved (and minted on first install) by
        // `MobileAnalyticsComposition`, which is constructed before this shell and
        // owns the `ios_app_first_launch` emit. The shell only needs the stable id
        // here — by the time it resolves, the value is already persisted, so its
        // `created` flag is always false and is intentionally not read.
        self.clientID = clientIDRepository.resolveClientID().id
        self.isSignedIn = isSignedIn
        self.connectionState = connectionState
        self.macConnectionStatus = connectionState == .connected ? .connected : .unavailable
        self.connectedHostName = connectedHostName
        self.pairingCode = pairingCode
        self.workspaces = workspaces
        self.terminalInputText = ""
        self.connectionError = nil
        self.connectionErrorGuidance = nil
        self.pairingVersionWarning = nil
        self.activeTicket = nil
        self.activeRoute = nil
        self.selectedWorkspaceID = workspaces.first?.id
        self.selectedTerminalID = workspaces.first?.terminals.first?.id
        self.remoteClient = nil
        self.terminalEventListenerTask = nil
        self.terminalEventListenerID = nil
        self.terminalSubscriptionRefreshTask = nil
        self.createWorkspaceTask = nil
        self.createTerminalTask = nil
        self.workspaceListRefreshTask = nil
        self.pullToRefreshTask = nil
        self.createWorkspaceTaskID = nil
        self.createTerminalTaskID = nil
        self.connectionGeneration = UUID()
        self.connectionAttemptGeneration = UUID()
        self.reportedViewportSizesByTerminalKey = [:]
        self.deliveredTerminalByteEndSeqBySurfaceID = [:]
        self.pendingTerminalByteEndSeqBySurfaceID = [:]
        self.terminalReplaySurfaceIDsInFlight = []
        self.terminalOutputTransport = .rawBytes
        self.terminalByteContinuationsBySurfaceID = [:]
        self.terminalOutputStreamTokensBySurfaceID = [:]
        self.terminalOutputQueuesBySurfaceID = [:]
        self.terminalScrollQueueTokensBySurfaceID = [:]
        self.terminalScrollQueuesBySurfaceID = [:]
        self.terminalScrollbackPrefetchStatesBySurfaceID = [:]
        self.rawTerminalInputBuffer = MobileTerminalInputSendBuffer()
        self.pairingAttemptID = UUID()
    }

    isolated deinit {
        presenceTask?.cancel()
        networkPathObservationTask?.cancel()
        terminalEventListenerTask?.cancel()
        terminalSubscriptionStartTask?.cancel()
        renderGridLivenessTimer?.cancel()
        renderGridLivenessProbeTask?.cancel()
        terminalSubscriptionRefreshTask?.cancel()
        createWorkspaceTask?.cancel()
        createTerminalTask?.cancel()
        workspaceListRefreshTask?.cancel()
        pullToRefreshTask?.cancel()
        if let remoteClient {
            Task { await remoteClient.disconnect() }
        }
    }

    public static func preview(runtime: (any MobileSyncRuntime)? = nil) -> CMUXMobileShellStore {
        CMUXMobileShellStore(
            runtime: runtime,
            workspaces: PreviewMobileHost.workspaces,
            deliveredNotificationClearer: NoopDeliveredNotificationClearer()
        )
    }

    public func signIn() {
        let wasSignedIn = isSignedIn
        isSignedIn = true
        clearPairingError()
        // Fire only on the signed-out→signed-in edge (this is called on every
        // auth-state sync), so identify + the sign-in-completed funnel event are
        // emitted once per sign-in.
        guard !wasSignedIn else { return }
        if let userID = identityProvider?.currentUserID {
            // Merge the pre-auth anonymous funnel (keyed on the install client id)
            // into the authenticated profile.
            analytics.identify(userId: userID, alias: clientID, properties: [:])
            analytics.setSuperProperties(["is_authenticated": .bool(true)])
        }
        analytics.capture("ios_sign_in_completed", [
            "is_new_user": .bool(false),
        ])
    }

    public func signOut() {
        // Reset analytics identity to anonymous on the signed-in→signed-out edge
        // only (this is called on every unauthenticated auth-state sync).
        if isSignedIn {
            analytics.identify(userId: nil, alias: nil, properties: [:])
            analytics.setSuperProperties(["is_authenticated": .bool(false)])
        }
        suppressNextConnectionOutageEdge = true
        invalidatePairingAttempt()
        connectionGeneration = UUID()
        connectionAttemptGeneration = UUID()
        isSignedIn = false
        connectionState = .disconnected
        macConnectionStatus = .unavailable
        connectedHostName = ""
        pairingCode = ""
        clearPairingVersionWarning()
        // Wipe every saved draft so the next account never sees the previous
        // user's unsent text. Guard the in-memory clear (and the selection resets
        // below) so the per-terminal draft hooks do not write partial state into a
        // store we are about to empty wholesale.
        isLoadingDraft = true
        terminalInputText = ""
        // Enqueued on the FIFO draft pipeline so every save issued before this
        // point is applied first and then wiped; a pending keystroke save can
        // never land after the wipe and leak into the next account's session.
        if let draftStore {
            enqueueDraftOperation { await draftStore.clearAllDrafts() }
        }
        // Drop unflushed keystroke snapshots too: an armed flush that runs
        // before the wipe would only write text the wipe then deletes, but the
        // buffer itself must not carry one account's text into the next.
        pendingDraftSaveTextByTerminalID = [:]
        // Per-terminal composer dismissals are this user's session UI state; the
        // next account starts with the default-open composer everywhere. Clear
        // the focus mirror BEFORE the selection resets below so the terminal
        // switch they trigger cannot arm a stale focus request, and drop any
        // already-armed handshake (the selection reset's didSet only clears it
        // when the terminal id actually changes).
        composerDismissedTerminalIDs = []
        composerFieldIsFocused = false
        composerFocusRequestPending = false
        composerFocusRequestTerminalID = nil
        clearPairingError()
        activeTicket = nil
        activeRoute = nil
        // Drop the cached paired Macs so the next signed-in user never sees the
        // previous user's hosts in the switcher.
        pairedMacs = []
        // Likewise drop the registry-backed device tree so a shared device never
        // shows the previous user's team devices after sign-out.
        registryDevices = []
        // Reset the in-memory restoring flags; hasKnownPairedMac stays driven by
        // the forget path. On a real account switch the next reconnect's no-mac
        // branch clears the hint. Bump the reconnect generation so any in-flight
        // reconnect is superseded and can't re-set these flags after sign-out.
        storedMacReconnectGeneration &+= 1
        isReconnectingStoredMac = false
        didFinishStoredMacReconnectAttempt = false
        replaceRemoteClient(with: nil)
        cancelRemoteOperationTasks()
        rawTerminalInputBuffer.clear()
        reportedViewportSizesByTerminalKey = [:]
        workspaces = PreviewMobileHost.workspaces
        // Group sections are account-scoped like `pairedMacs`/`registryDevices`
        // above: the placeholder workspaces are ungrouped, and the previous
        // account's group names must not survive into the next session. (Plain
        // disconnect intentionally keeps groups together with the last-known
        // workspace snapshot for the offline view; the next full list response
        // replaces both wholesale.)
        workspaceGroups = []
        selectedWorkspaceID = workspaces.first?.id
        selectedTerminalID = workspaces.first?.terminals.first?.id
        // Selection resets above are done; allow draft saving again so a
        // subsequent sign-in restores drafts normally.
        isLoadingDraft = false
    }

    public func resumeForegroundRefresh() {
        startObservingNetworkPathChanges()
        // Covers stores constructed already-signed-in (no isSignedIn edge) and
        // restarts a subscription torn down while backgrounded.
        evaluatePresenceSubscription()
        resyncTerminalOutput(reason: "foreground", restartEventStream: true)
    }

    /// Forward a tap to the Mac's real surface as a left click at the given grid
    /// cell. libghostty self-gates: a TUI with mouse reporting receives the
    /// click; a normal screen treats it as a harmless empty selection. The
    /// render-grid mirrors any resulting change back. Fire-and-forget.
    public func clickTerminal(surfaceID: String, col: Int, row: Int) async {
        guard let client = remoteClient,
              let workspaceID = workspaceID(forTerminalID: surfaceID) else {
            return
        }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.terminal.mouse",
                params: [
                    "workspace_id": workspaceID.rawValue,
                    "surface_id": surfaceID,
                    "client_id": clientID,
                    "col": col,
                    "row": row,
                ]
            )
            _ = try await client.sendRequest(request)
        } catch {
            mobileShellLog.error("click forward failed surface=\(surfaceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Feedback routing

    /// An all-empty stamp used when no app-layer provider is injected (previews /
    /// tests). A real build always injects a populated provider at the
    /// composition root.
    public static let emptyFeedbackStamp = MobileFeedbackStamp(
        buildType: .prod,
        appVersion: "",
        appBuild: "",
        bundleIdentifier: "",
        osVersion: "",
        deviceModel: ""
    )

    /// The signed-in user's primary email, read through the identity seam.
    ///
    /// Used by the Send Feedback affordance to decide the route (privileged vs
    /// email) and to prefill the reply-to address on the email path.
    public var signedInUserEmail: String? {
        identityProvider?.currentUserEmail
    }

    /// Whether the device currently has an active mobile-host connection to a
    /// paired Mac — the implementable "on the tailnet" proxy used by feedback
    /// routing, since that transport runs over Tailscale.
    public var hasActiveMacConnection: Bool {
        connectionState == .connected && remoteClient != nil
    }

    /// Where a Send Feedback submission should be delivered right now.
    ///
    /// Pure decision over the current email + connection state; the privileged
    /// direct-to-agent route is offered only to `@manaflow.ai` users on an
    /// active connection, everyone else routes to the email inbox.
    public var currentFeedbackRoute: MobileFeedbackRoute {
        MobileFeedbackRoute.resolve(
            email: signedInUserEmail,
            hasActiveMacConnection: hasActiveMacConnection,
            hostSupportsAgentSink: supportsDogfoodFeedback
        )
    }

    /// The current build + device stamp, resolved through the injected provider.
    public var currentFeedbackStamp: MobileFeedbackStamp {
        feedbackStampProvider()
    }

    /// Outcome of a Send Feedback submission, including which route was taken so
    /// the UI can word its confirmation ("sent to the agent" vs "emailed").
    public enum FeedbackSubmissionOutcome: Equatable, Sendable {
        /// The rich diagnostic bundle was delivered to the paired Mac.
        case sentToAgent
        /// The message was emailed to the feedback inbox.
        case emailed
        /// Delivery failed; the UI should surface an error and let the user retry.
        case failed
    }

    /// The single Send Feedback entrypoint. Routes the submission to the
    /// privileged direct-to-agent bundle or the email inbox per
    /// ``currentFeedbackRoute``, stamping the build + device on both paths.
    ///
    /// One mutation path so every surface (the menu affordance, and any future
    /// entrypoint) shares the same routing, stamping, and delivery rather than
    /// duplicating it.
    ///
    /// - Parameters:
    ///   - message: The freeform feedback body.
    ///   - emailOverride: The reply-to email when the user edited it on the email
    ///     path; defaults to the signed-in email.
    ///   - debugLogText: The string debug-log snapshot, used only on the agent
    ///     path.
    ///   - terminalText: The visible terminal text, used only on the agent path.
    /// - Returns: The outcome (which route succeeded, or `.failed`).
    @discardableResult
    public func submitFeedback(
        message: String,
        emailOverride: String? = nil,
        debugLogText: String,
        terminalText: String
    ) async -> FeedbackSubmissionOutcome {
        let stamp = currentFeedbackStamp
        switch currentFeedbackRoute {
        case .privilegedAgent:
            let ok = await submitPrivilegedAgentFeedback(
                text: message,
                debugLogText: debugLogText,
                terminalText: terminalText,
                buildStamp: stamp.agentBuildStamp
            )
            if ok {
                return .sentToAgent
            }
            // The agent sink failed (e.g. the Mac rejected the privileged sink,
            // or the RPC could not be delivered). Fall back to the email inbox
            // rather than dead-ending, so the report is still delivered. Any
            // valid reply-to works; we have the signed-in email here.
            mobileShellLog.error("privileged agent feedback failed; falling back to email")
            return await submitFeedbackEmail(message: message, emailOverride: emailOverride, stamp: stamp)
        case .email:
            return await submitFeedbackEmail(message: message, emailOverride: emailOverride, stamp: stamp)
        }
    }

    /// Email the feedback inbox, returning `.emailed` on success and `.failed`
    /// when the submitter is unavailable or the POST fails. Shared by the email
    /// route and the privileged-agent fallback so both deliver identically.
    private func submitFeedbackEmail(
        message: String,
        emailOverride: String?,
        stamp: MobileFeedbackStamp
    ) async -> FeedbackSubmissionOutcome {
        guard let submitter = feedbackEmailSubmitter else {
            mobileShellLog.error("feedback email submitter unavailable")
            return .failed
        }
        let email = (emailOverride ?? signedInUserEmail ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await submitter.submit(email: email, message: message, stamp: stamp)
            return .emailed
        } catch {
            mobileShellLog.error("feedback email submit failed error=\(String(describing: error), privacy: .public)")
            return .failed
        }
    }

    // MARK: - Network recovery

    /// True while an automatic reconnect is in progress after a network change
    /// or drop.
    public private(set) var isRecoveringConnection: Bool = false
    /// True when automatic recovery could not restore the connection; the UI
    /// surfaces a manual Retry control in this state.
    public private(set) var connectionRecoveryFailed: Bool = false {
        didSet {
            // Fire once on the false→true edge ("stuck disconnected, Retry is
            // dead"): the recovery-rate denominator.
            guard !oldValue, connectionRecoveryFailed else { return }
            var props: [String: AnalyticsValue] = [:]
            if let startedAt = connectionOutageStartedAt {
                let ms = Int(((runtime?.now() ?? Date()).timeIntervalSince(startedAt)) * 1000)
                props["outage_duration_ms"] = .int(max(0, ms))
            }
            analytics.capture("ios_connection_recovery_failed", props)
        }
    }
    /// True when the host rejected this device on authorization grounds (the Mac
    /// is signed in to a different account, or the token could not be verified).
    /// Retrying cannot fix this, so the UI surfaces the auth message and a
    /// Sign Out action instead of a Retry control. ``connectionError`` carries
    /// the user-facing reason.
    public private(set) var connectionRequiresReauth: Bool = false

    private var networkPathObservationStarted = false
    private var networkPathObservationTask: Task<Void, Never>?
    private var recoveryInFlight = false
    private var recoveryTask: Task<Void, Never>?
    private var lastReconnectStackUserID: String?

    private enum RecoveryTrigger: CustomStringConvertible {
        case networkChange
        case manual
        case presencePush
        var description: String {
            switch self {
            case .networkChange: return "networkChange"
            case .manual: return "manual"
            case .presencePush: return "presencePush"
            }
        }
    }

    /// Begin observing meaningful network path changes (Wi-Fi<->cellular,
    /// offline->online) so a live terminal recovers when the network moves out
    /// from under it. Idempotent; only the first call arms the observation.
    func startObservingNetworkPathChanges() {
        guard !networkPathObservationStarted else { return }
        networkPathObservationStarted = true
        let reachability = reachability
        networkPathObservationTask = Task { @MainActor [weak self] in
            // Each yield marks a meaningful path change (offline->online or a
            // primary-interface switch while online); recover the live
            // connection so a moving network repaints instead of going stale.
            for await _ in reachability.pathChanges() {
                guard let self, !Task.isCancelled else { return }
                self.recoverMobileConnection(trigger: .networkChange)
            }
        }
    }

    /// User-initiated reconnect from the Retry control.
    public func retryMobileConnection() {
        connectionRecoveryFailed = false
        recoverMobileConnection(trigger: .manual)
    }

    /// Single guarded recovery entry for every trigger (network change, manual
    /// Retry). When still connected, a network move usually only broke the event
    /// stream while input keeps flowing over the surviving connection, so a
    /// resync re-subscribes and requests a render-grid replay to repaint.
    /// Otherwise the connection dropped, so reconnect once; on failure the UI
    /// shows Retry and the next network change re-attempts automatically.
    private func recoverMobileConnection(trigger: RecoveryTrigger) {
        guard remoteClient != nil || pairedMacStore != nil else { return }
        if connectionState == .connected, remoteClient != nil {
            markMacConnectionReconnecting()
            resyncTerminalOutput(reason: "networkRecovery.\(trigger)", restartEventStream: true)
            return
        }
        guard !recoveryInFlight else { return }
        recoveryInFlight = true
        isRecoveringConnection = true
        connectionRecoveryFailed = false
        let stackUserID = lastReconnectStackUserID
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            defer {
                self?.recoveryInFlight = false
                self?.isRecoveringConnection = false
            }
            guard let self, self.connectionState != .connected else { return }
            let reconnected = await self.reconnectActiveMacIfAvailable(stackUserID: stackUserID)
            if !reconnected, !Task.isCancelled {
                self.connectionRecoveryFailed = true
            }
        }
    }

    public func connectPreviewHost() {
        let trimmedCode = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            return
        }
        if trimmedCode.hasPrefix("cmux-ios://") {
            return
        }
        let attemptID = beginPairingAttempt()
        replaceRemoteClient(with: nil)
        clearPairingError()
        activeTicket = nil
        activeRoute = nil
        connectedHostName = PreviewMobileHost.hostName
        guard isCurrentPairingAttempt(attemptID) else { return }
        connectionState = .connected
        markMacConnectionHealthy()
        if selectedWorkspaceID == nil {
            selectedWorkspaceID = workspaces.first?.id
        }
        syncSelectedTerminalForWorkspace()
    }

    public func connectPairingInput() async {
        let trimmedCode = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            return
        }
        if trimmedCode.hasPrefix("cmux-ios://") {
            await connectPairingURL(trimmedCode)
            return
        }
        connectPreviewHost()
    }

    public func connectManualHost(name: String, host: String, port: Int) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedHost = MobileShellRouteAuthPolicy.normalizedManualHost(host) else {
            connectionError = L10n.string("mobile.addDevice.invalidHost", defaultValue: "Enter a host or IP address, without spaces or URL paths.")
            connectionErrorGuidance = nil
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
            analytics.capture("ios_pairing_failed", [
                "method": .string("manual"),
                "reason": .string("invalid_host"),
                "failure_phase": .string("validation"),
                "is_first_pair": .bool(!hasKnownPairedMac),
            ])
            return
        }
        guard (1...65535).contains(port) else {
            connectionError = L10n.string("mobile.addDevice.invalidPort", defaultValue: "Enter a port from 1 to 65535.")
            connectionErrorGuidance = nil
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
            analytics.capture("ios_pairing_failed", [
                "method": .string("manual"),
                "reason": .string("invalid_port"),
                "failure_phase": .string("validation"),
                "is_first_pair": .bool(!hasKnownPairedMac),
            ])
            return
        }

        let directRoute = try? Self.manualHostRoute(host: normalizedHost, port: port)
        let attemptID = beginPairingAttempt(method: "manual")
        // Fast offline preflight: fail immediately instead of stacking
        // per-route timeouts into the opaque ~60s blob.
        let manualRoutes = directRoute.map { [$0] } ?? []
        guard await failPairingIfOffline(attemptID: attemptID, phase: "preflight", routes: manualRoutes) == .proceed else { return }
        do {
            let ticket = try await manualHostTicket(
                name: trimmedName,
                host: normalizedHost,
                port: port
            )
            guard isCurrentPairingAttempt(attemptID) else { return }
            let noThrowFailure = try await connect(ticket: ticket, allowsStackAuthFallback: true)
            guard isCurrentPairingAttempt(attemptID) else { return }
            if connectionState == .connected {
                recordPairingSucceeded()
            } else {
                // `connect()` returned without connecting and already set a
                // specific error; record without overwriting that message.
                recordFailureForCurrentConnectionError(phase: "connect", category: noThrowFailure)
            }
        } catch is CancellationError {
            guard isCurrentPairingAttempt(attemptID) else { return }
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
        } catch {
            guard isCurrentPairingAttempt(attemptID) else { return }
            mobileShellLog.error("manual host pairing failed: \(String(describing: error), privacy: .private)")
            // A definitive auth failure (expired/invalid token after the
            // refresh-then-retry in the RPC layer already gave up) must drive the
            // re-auth prompt, not the generic "could not connect / Retry" banner.
            if disconnectForAuthorizationFailureIfNeeded(error) {
                return
            }
            let category = MobilePairingFailureCategory.classify(error: error, route: activeRoute ?? directRoute)
            applyPairingFailure(category, phase: "connect")
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
        }
    }

    /// On launch (after StackAuth has bootstrapped), call this to reconnect
    /// to the last-active paired Mac. Pulls (route, displayName, macDeviceID)
    /// from SQLite and re-mints an attach ticket via the StackAuth-authenticated
    /// manual host flow. Auth tokens never persist; we always re-mint.
    @discardableResult
    public func reconnectActiveMacIfAvailable(stackUserID: String?) async -> Bool {
        lastReconnectStackUserID = stackUserID
        startObservingNetworkPathChanges()
        // Claim this attempt's generation. Only the current generation may resolve
        // the restoring-gate flags, so an older superseded attempt can't clear the
        // gate (or clobber the hint) while a newer reconnect is still running.
        storedMacReconnectGeneration &+= 1
        let generation = storedMacReconnectGeneration
        // No store / not signed in: can't determine a stored Mac here. Resolve the
        // restoring gate (so a returning user doesn't spin on RestoringSessionView)
        // but leave the persisted hint intact for a future attempt.
        guard let pairedMacStore else {
            finishStoredMacReconnectAttempt(generation: generation)
            return false
        }
        guard isSignedIn else {
            finishStoredMacReconnectAttempt(generation: generation)
            return false
        }
        let saved: MobilePairedMac?
        do {
            saved = try await pairedMacStore.activeMac(stackUserID: stackUserID)
        } catch {
            mobileShellLog.error("paired mac store activeMac failed: \(String(describing: error), privacy: .public)")
            // A read failure means "couldn't determine," not "no mac": keep the
            // hint so a transient SQLite error doesn't erase a returning user's
            // paired state.
            finishStoredMacReconnectAttempt(generation: generation)
            return false
        }
        guard let mac = saved else {
            // Definitively no active Mac: clear the hint so future launches show
            // the add-device sheet immediately with no restoring flash.
            setHasKnownPairedMac(false, generation: generation)
            finishStoredMacReconnectAttempt(generation: generation)
            return false
        }
        // Kick off a best-effort registry refresh for this Mac in the background.
        // It does NOT block the connect below: the common case (fresh local
        // routes) reconnects immediately with no network round-trip. If the Mac
        // moved networks / changed port, the refreshed routes land in the store
        // and the next reconnect trigger (network change or Retry) uses them.
        refreshRoutesFromRegistry(for: mac, stackUserID: stackUserID)
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        guard let (host, port) = Self.firstReconnectHostPortRoute(
            mac.routes,
            supportedKinds: supportedKinds
        ) else {
            // Found a Mac but no usable route to reach it: treat as no reconnect
            // target and fall through to add-device.
            setHasKnownPairedMac(false, generation: generation)
            finishStoredMacReconnectAttempt(generation: generation)
            return false
        }
        // A newer attempt may have started while we awaited the store read; if so,
        // let it own the flags rather than marking ourselves the active reconnect.
        guard generation == storedMacReconnectGeneration else { return false }
        setHasKnownPairedMac(true, generation: generation)
        isReconnectingStoredMac = true
        // Cap how long the restoring gate stays up: a stored Mac whose route went
        // stale (Tailscale address changed, or it's offline) makes connectManualHost
        // hang on a slow connect timeout, and the gate shows RestoringSessionView for
        // that whole time. After the deadline, resolve the gate so the user reaches
        // add-device quickly; the connect keeps trying, so a later success still
        // flips connectionState to .connected and shows the workspaces.
        let restoringDeadline = Task { [weak self] in
            // Bounded, cancellable deadline (not a poll) — cancelled the instant the
            // connect resolves; only caps the restoring-gate window.
            try? await ContinuousClock().sleep(
                for: .seconds(Self.storedMacReconnectRestoringDeadlineSeconds)
            )
            guard let self, !Task.isCancelled,
                  generation == self.storedMacReconnectGeneration,
                  self.connectionState != .connected else { return }
            self.isReconnectingStoredMac = false
            self.didFinishStoredMacReconnectAttempt = true
        }
        await connectManualHost(name: mac.displayName ?? host, host: host, port: port)
        restoringDeadline.cancel()
        // A newer attempt may have started during the connect; it now owns the flags.
        guard generation == storedMacReconnectGeneration else { return false }
        isReconnectingStoredMac = false
        didFinishStoredMacReconnectAttempt = true
        return connectionState == .connected
    }

    /// Writes the persisted paired-Mac hint only when `generation` is still the
    /// current reconnect attempt, so a superseded attempt can't clobber a newer
    /// attempt's determination.
    private func setHasKnownPairedMac(_ value: Bool, generation: Int) {
        guard generation == storedMacReconnectGeneration else { return }
        hasKnownPairedMac = value
    }

    /// Mark the stored-Mac reconnect attempt resolved without a live connection,
    /// but only when `generation` is still current.
    ///
    /// Clears ``isReconnectingStoredMac`` and sets
    /// ``didFinishStoredMacReconnectAttempt`` so the root scene falls through to
    /// the disconnected/add-device view instead of spinning on the restoring UI.
    /// A superseded attempt (older `generation`) is a no-op so it can't resolve the
    /// gate while a newer reconnect is in progress.
    private func finishStoredMacReconnectAttempt(generation: Int) {
        guard generation == storedMacReconnectGeneration else { return }
        isReconnectingStoredMac = false
        didFinishStoredMacReconnectAttempt = true
    }

    /// Best-effort, non-blocking registry refresh for the active paired Mac.
    ///
    /// Runs detached so it never adds latency to the in-flight reconnect (which
    /// connects on the locally persisted routes). When the registry returns
    /// usable, *different* routes for this Mac, they are written back into the
    /// store so the next reconnect trigger (network change / Retry) reaches the
    /// Mac at its current address after it moved networks or changed port. A
    /// missing registry, an unauthorized call, or no-change routes are no-ops, so
    /// a registry outage never disturbs the locally stored routes.
    private func refreshRoutesFromRegistry(for mac: MobilePairedMac, stackUserID: String?) {
        guard let deviceRegistry, let pairedMacStore else { return }
        let macDeviceID = mac.macDeviceID
        let localRoutes = mac.routes
        let displayName = mac.displayName
        Task { [weak self] in
            let registryRoutes = await deviceRegistry.freshRoutes(forMacDeviceID: macDeviceID)
            guard let updated = DeviceRegistryService.selectReconnectRoutes(
                local: localRoutes,
                registry: registryRoutes
            ) else { return }
            guard let self else { return }
            // The network await above suspended; the user may have signed out,
            // switched accounts, forgotten this Mac, or switched the active Mac
            // meanwhile. Re-evaluate against the *current* store/identity before
            // the `markActive: true` upsert, so a stale refresh can never
            // resurrect or reactivate a pairing the user removed. Mirrors the
            // user-switch guard in `loadPairedMacs`.
            let activeMacID: String?
            do {
                activeMacID = try await pairedMacStore.activeMac(stackUserID: stackUserID)?.macDeviceID
            } catch {
                mobileShellLog.debug("registry refresh active-mac recheck failed: \(String(describing: error), privacy: .public)")
                return
            }
            guard DeviceRegistryService.shouldApplyRegistryRefresh(
                isSignedIn: self.isSignedIn,
                capturedUserID: stackUserID,
                currentUserID: self.identityProvider?.currentUserID,
                activeMacID: activeMacID,
                targetMacID: macDeviceID
            ) else { return }
            do {
                try await pairedMacStore.upsert(
                    macDeviceID: macDeviceID,
                    displayName: displayName,
                    routes: updated,
                    markActive: true,
                    stackUserID: stackUserID
                )
            } catch {
                mobileShellLog.debug("registry route refresh upsert failed: \(String(describing: error), privacy: .public)")
                return
            }
            await self.loadPairedMacs()
        }
    }

    // MARK: - Paired Mac switching

    /// Every Mac paired with this device, for the host switcher. Refreshed via
    /// ``loadPairedMacs()`` and after switch/forget. Cleared on sign-out so a
    /// shared device never shows the previous user's Macs. The active row is
    /// marked by each ``MobilePairedMac/isActive`` flag (the live connection's
    /// attach ticket carries a transient manual id, so it is not a reliable
    /// active marker on its own).
    public private(set) var pairedMacs: [MobilePairedMac] = [] {
        didSet {
            guard oldValue.count != pairedMacs.count else { return }
            analytics.setSuperProperties(["paired_mac_count": .int(pairedMacs.count)])
        }
    }

    // MARK: - Device registry tree

    /// The team's registered devices and their cmux app instances (tags), for the
    /// device tree (device → tags → workspaces). Fetched from the team-scoped
    /// device registry via ``loadRegistryDevices()``. Empty until the first load,
    /// when the registry is unreachable, or after sign-out. Best-effort: a
    /// registry outage leaves this empty and the UI falls back to the locally
    /// known paired Macs, so the tree degrades to the same hosts the switcher
    /// shows rather than going blank.
    public private(set) var registryDevices: [RegistryDevice] = []

    /// The cmux device id of the Mac the live connection currently targets, or
    /// `nil` when not connected. Used by the device tree to mark which device row
    /// is live.
    ///
    /// Prefers the active attach ticket's real `macDeviceID`. A manual (`manual-…`)
    /// ticket has no real device id (the host lacks `mobile.attach_ticket.create`,
    /// so the connect synthesizes a manual ticket even on success); in that case,
    /// fall back to the active paired Mac's device id, which the registry/switch
    /// connect paths persist on success. This keeps the connected device — and its
    /// live workspaces — visible in the tree even when the live ticket is manual.
    /// Yields `nil` only when there is genuinely no real device id to correlate.
    public var connectedMacDeviceID: String? {
        guard connectionState == .connected else { return nil }
        if let macDeviceID = activeTicket?.macDeviceID,
           !macDeviceID.isEmpty,
           !macDeviceID.hasPrefix("manual-") {
            return macDeviceID
        }
        // Manual/synthetic ticket but a live connection: correlate via the active
        // paired Mac the connect path persisted (its id is the real device id).
        if let activeMacID = pairedMacs.first(where: { $0.isActive })?.macDeviceID,
           !activeMacID.isEmpty,
           !activeMacID.hasPrefix("manual-") {
            return activeMacID
        }
        return nil
    }

    /// Reload ``registryDevices`` from the team-scoped device registry.
    ///
    /// Best-effort and failure-tolerant: a missing registry, an unauthorized
    /// call, or a malformed response leaves the current list untouched (so a
    /// transient blip never blanks a populated tree). Devices are sorted with the
    /// currently-connected one first, then by most-recently-seen, so the tree
    /// leads with the host the user is on. Mirrors ``loadPairedMacs()``: signed
    /// out yields an empty list.
    public func loadRegistryDevices() async {
        guard isSignedIn, let deviceRegistry else {
            registryDevices = []
            return
        }
        // Capture the requesting user so a result that lands after a sign-out +
        // different-user sign-in is discarded, not assigned into the new user's
        // tree. `isSignedIn` alone is true again after the switch, so it cannot
        // catch this account-switch race (mirrors loadPairedMacs's user guard).
        let requestingUserID = identityProvider?.currentUserID
        let outcome = await deviceRegistry.listDevices()
        let loaded: [RegistryDevice]
        switch outcome {
        case .ok(let devices):
            loaded = devices
        case .authRejected:
            // The registry is team-scoped and rejected the call on auth/scope
            // grounds (401/403): the cached list may be another scope's data, so
            // clear it. The tree falls back to local paired Macs via
            // `deviceTreeDevices`, so the sheet stays usable. Guarded on the
            // requesting user still being current (mirroring the `.ok` path):
            // a stale 401 from a signed-out session that lands after a
            // different user signed in must not blank the new user's tree.
            if identityProvider?.currentUserID == requestingUserID {
                registryDevices = []
            }
            return
        case .transientFailure:
            // Network blip / 5xx / malformed body: keep what we have rather than
            // blanking a populated tree on a transient failure.
            return
        }
        // The await above suspended the main actor; discard the result unless we
        // are still the same signed-in user, so a slow load can never repopulate
        // another user's team devices after sign-out or an account switch.
        guard isSignedIn, identityProvider?.currentUserID == requestingUserID else {
            registryDevices = []
            return
        }
        let connectedID = connectedMacDeviceID
        registryDevices = loaded.sorted { lhs, rhs in
            let lhsConnected = lhs.deviceId == connectedID
            let rhsConnected = rhs.deviceId == connectedID
            if lhsConnected != rhsConnected { return lhsConnected }
            return lhs.lastSeenAt > rhs.lastSeenAt
        }
    }

    /// The device-tree data source, honoring the registry's best-effort/fallback
    /// contract: the registry list when it loaded, otherwise the locally paired
    /// Macs synthesized into the same two-level shape.
    ///
    /// When `/api/devices` is unreachable, unauthorized, or malformed,
    /// ``registryDevices`` stays empty; the tree must not collapse to "no devices"
    /// while the phone still has usable paired Macs. Each paired Mac becomes a
    /// device with a single `default` instance carrying its routes, so the tree
    /// (and its connect-on-tap) keeps working with the cloud down. The connected
    /// device sorts first, then most-recently-seen.
    public var deviceTreeDevices: [RegistryDevice] {
        if !registryDevices.isEmpty { return registryDevices }
        let connectedID = connectedMacDeviceID
        return pairedMacs
            .map { mac in
                RegistryDevice(
                    deviceId: mac.macDeviceID,
                    platform: "mac",
                    displayName: mac.displayName,
                    lastSeenAt: mac.lastSeenAt,
                    instances: [
                        RegistryAppInstance(
                            tag: "default",
                            routes: mac.routes,
                            lastSeenAt: mac.lastSeenAt
                        )
                    ]
                )
            }
            .sorted { lhs, rhs in
                let lhsConnected = lhs.deviceId == connectedID
                let rhsConnected = rhs.deviceId == connectedID
                if lhsConnected != rhsConnected { return lhsConnected }
                return lhs.lastSeenAt > rhs.lastSeenAt
            }
    }

    // MARK: - Live presence

    /// Live per-instance presence from the presence service (`workers/presence`),
    /// applied snapshot-first then event-by-event. Empty until the first
    /// snapshot; the device tree then overlays live online/offline state on the
    /// registry rows instead of registry "last seen" staleness guesses.
    public private(set) var presenceMap = PresenceMap()
    private var presenceTask: Task<Void, Never>?

    /// Start or stop the presence subscription to match the session: running
    /// while signed in (and a client is injected), torn down with a blanked map
    /// on sign-out. Idempotent; called from the `isSignedIn` edge and from
    /// `resumeForegroundRefresh()` for stores constructed already-signed-in.
    private func evaluatePresenceSubscription() {
        if isSignedIn, presence != nil {
            startPresenceSubscription()
        } else {
            presenceTask?.cancel()
            presenceTask = nil
            presenceMap = PresenceMap()
        }
    }

    /// Run the subscribe stream with exponential backoff (1s..60s, reset on
    /// every received frame). The server bounds each stream to the token's
    /// expiry, so a clean finish (resubscribe with a fresh token) is the
    /// steady state, not an error. Backoff sleeps are cancellable and the task
    /// is cancelled on sign-out/deinit, so the loop never outlives the store.
    private func startPresenceSubscription() {
        guard presenceTask == nil, let presence else { return }
        presenceTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            var backoff: Duration = .seconds(1)
            while !Task.isCancelled {
                do {
                    let stream = try await presence.subscribe()
                    for try await update in stream {
                        guard let self, !Task.isCancelled else { return }
                        backoff = .seconds(1)
                        self.applyPresenceUpdate(update)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    mobileShellLog.debug(
                        "presence stream ended: \(String(describing: error), privacy: .public)"
                    )
                }
                if Task.isCancelled { return }
                guard (try? await clock.sleep(for: backoff)) != nil else { return }
                backoff = min(backoff * 2, .seconds(60))
            }
        }
    }

    private func applyPresenceUpdate(_ update: PresenceUpdate) {
        presenceMap.apply(update)
        switch update {
        case .routes(let instance), .online(let instance):
            // Both events can carry fresh attach routes (online = a host that
            // re-announced after moving networks while the phone was watching).
            syncPushedRoutes(from: instance)
        case .snapshot(let snapshot):
            // The snapshot is the reconcile-on-(re)subscribe path: a port that
            // changed while the phone was offline lands here. One batch (not
            // one task per instance) so a multi-tag Mac syncs routes in
            // deterministic order and kicks at most one reconnect.
            syncPushedRoutes(from: snapshot.devices.flatMap { device in
                device.instances.filter(\.online)
            })
        case .offline, .seen:
            break
        }
    }

    /// Write presence-pushed attach routes through to the local paired-Mac
    /// store (the same merge the registry refresh uses), so the next reconnect
    /// dials the host's fresh port/IP without a registry round trip — and kick
    /// a reconnect when the phone is sitting disconnected from that very Mac.
    ///
    /// Presence only updates Macs the user already paired; it never creates a
    /// pairing. A live, healthy connection is never torn down here: if the
    /// route the live session uses disappeared, the transport notices on its
    /// own and the next reconnect picks up the stored fresh routes.
    private func syncPushedRoutes(from instance: PresenceInstance) {
        syncPushedRoutes(from: [instance])
    }

    /// Batch form: one sequential task for the whole delivery (a snapshot can
    /// carry several online instances, including multiple tags on one Mac),
    /// so route upserts apply in deterministic order and the reconnect kick
    /// fires at most once per delivery instead of once per instance.
    private func syncPushedRoutes(from instances: [PresenceInstance]) {
        let candidates = instances.filter { $0.platform.lowercased() != "ios" }
        guard !candidates.isEmpty else { return }
        let stackUserID = identityProvider?.currentUserID
        // Every await below suspends the main actor, so re-check after
        // each one that the frame's user is still the signed-in user: a
        // stale presence frame from a previous account must never write
        // routes into, or kick reconnects for, the next session (mirrors
        // refreshRegistryDevices' account-switch guard).
        let userIsCurrent: () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.isSignedIn && self.identityProvider?.currentUserID == stackUserID
        }
        // Serialized on the paired-Mac write chain: a (re)subscribe delivers
        // a snapshot immediately followed by online/routes events for the
        // same device, and two concurrent deliveries would race their
        // pairedMacStore upserts and could each kick a reconnect. The chain
        // appends synchronously on the main actor, so deliveries execute
        // strictly in arrival order.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performSerializedPairedMacWrite(ifStillCurrent: userIsCurrent) {
                [weak self] in
                guard let self else { return }
                if self.pairedMacs.isEmpty {
                    // A presence frame can land before the first paired-Mac
                    // load (snapshot arrives fast on launch); resolve the
                    // pairing list before deciding these devices are unknown.
                    await self.loadPairedMacs()
                }
                var onlineDeviceIds: Set<String> = []
                for instance in candidates {
                    guard userIsCurrent() else { return }
                    if instance.online { onlineDeviceIds.insert(instance.deviceId) }
                    await self.applyPushedRoutes(from: instance, stackUserID: stackUserID)
                }
                guard userIsCurrent() else { return }
                // The Mac this phone wants is online and we are not
                // connected: reconnect now instead of waiting for the user to
                // pull Retry. Unambiguous pushes were persisted above, so the
                // reconnect dials fresh routes; under the multi-instance
                // ambiguity guard the stored last-known-good routes are
                // deliberately kept and the reconnect uses those, the same
                // outcome a manual Retry would have.
                if self.connectionState != .connected,
                   let activeMacID = self.pairedMacs.first(where: { $0.isActive })?.macDeviceID,
                   onlineDeviceIds.contains(activeMacID) {
                    self.recoverMobileConnection(trigger: .presencePush)
                }
            }
        }
    }

    /// Per-instance store/registry write-through for the batch sync above.
    private func applyPushedRoutes(from instance: PresenceInstance, stackUserID: String?) async {
        // `nil` means the host did not announce routes on this record
        // ("unchanged" on the wire); an explicit `[]` is a live clear.
        guard let routes = instance.routes else { return }
        let deviceId = instance.deviceId
        guard let mac = pairedMacs.first(where: { $0.macDeviceID == deviceId }) else {
            return
        }
        // Mirror the in-memory registry tree's Connect affordances first, so
        // an explicit empty set drops stale endpoints from the tree instead
        // of leaving a Connect affordance pointing at routes the host no
        // longer advertises.
        if let deviceIndex = registryDevices.firstIndex(where: { $0.deviceId == deviceId }),
           let instanceIndex = registryDevices[deviceIndex].instances
               .firstIndex(where: { $0.tag == instance.tag }) {
            registryDevices[deviceIndex].instances[instanceIndex].routes = routes
        }
        // The paired-Mac store keeps last-known-good reconnect routes, so only
        // a non-empty push updates it (same merge the registry refresh uses).
        // The store is device-level (no tag), so substitution must also stay
        // unambiguous: persist only when this device has exactly one online
        // route-advertising instance and it is the one that pushed, mirroring
        // the registry refresh's multi-instance guard. With a stable build and
        // a tagged debug build both live, keep the locally persisted routes
        // rather than risk reconnecting the phone to the wrong build's
        // workspaces.
        guard !routes.isEmpty,
              let sole = presenceMap.soleRouteAdvertisingInstance(deviceId: deviceId),
              sole.tag == instance.tag,
              let pairedMacStore,
              let updated = DeviceRegistryService.selectReconnectRoutes(
                  local: mac.routes,
                  registry: routes
              ) else { return }
        do {
            try await pairedMacStore.upsert(
                macDeviceID: deviceId,
                displayName: mac.displayName,
                routes: updated,
                markActive: mac.isActive,
                stackUserID: stackUserID
            )
            await loadPairedMacs()
        } catch {
            mobileShellLog.debug(
                "presence route upsert failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Connect the live session to a specific registry app instance (a tag on a
    /// device) using that instance's advertised routes.
    ///
    /// This is the device tree's tap-to-open for a tag that is not the currently
    /// connected one: it routes through the same destructive ``connectManualHost``
    /// path the multi-Mac switcher uses, then persists the device as the active
    /// paired Mac on success (so a later relaunch reconnects to it) and refreshes
    /// the paired-Mac list. A no-op when the instance advertises no reachable
    /// route. Failure surfaces through ``connectionError`` like any other connect.
    ///
    /// Like ``switchToMac(macDeviceID:)``, the connect is destructive (it replaces
    /// the live client), so tapping a stale/offline tag while connected would drop
    /// a healthy session. To avoid stranding the user, on a failed connect the
    /// previously-active Mac is reconnected, so a bad target leaves the user where
    /// they were rather than disconnected.
    /// - Parameters:
    ///   - device: The registry device the instance belongs to.
    ///   - instance: The tag/app-instance to connect to.
    public func connectToRegistryInstance(
        device: RegistryDevice,
        instance: RegistryAppInstance
    ) async {
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        guard let (host, port) = Self.firstReconnectHostPortRoute(
            instance.routes,
            supportedKinds: supportedKinds
        ), let normalizedHost = MobileShellRouteAuthPolicy.normalizedManualHost(host) else {
            mobileShellLog.error(
                "connectToRegistryInstance: no reconnectable route device=\(device.deviceId, privacy: .public) tag=\(instance.tag, privacy: .public)"
            )
            return
        }
        // Already connected to this exact device/instance route: nothing to do.
        if connectionState == .connected,
           connectedMacDeviceID == device.deviceId,
           case let .hostPort(liveHost, livePort)? = activeRoute?.endpoint,
           liveHost == normalizedHost, livePort == port {
            return
        }
        // The currently-active Mac to fall back to if the connect fails, so the
        // destructive connect below can be rolled back. Unlike switchToMac, this
        // does NOT exclude the tapped device: a Mac can run multiple tagged builds,
        // so tapping another tag on the *currently connected* device must still be
        // able to reconnect that same device's active route if the new tag is
        // stale/offline. Excluding it would strand the user on a same-device tag
        // switch failure.
        let previousActive = pairedMacs.first { $0.isActive }
        await connectManualHost(name: device.displayName ?? host, host: host, port: port)
        // Persist as the active paired Mac only when the live connection is to
        // THIS route (a switch tapped while this connect was in flight could win
        // the connection; matching the live route avoids persisting a stale
        // target). Uses the real device id so reconnect-on-relaunch finds it.
        guard connectionState == .connected,
              case let .hostPort(liveHost, livePort)? = activeRoute?.endpoint,
              liveHost == normalizedHost, livePort == port else {
            // The connect did not land on this route. If the destructive path
            // dropped a previously-active session, reconnect it so a failed tap on
            // a stale/offline tag does not strand the user disconnected.
            if previousActive != nil, connectionState != .connected {
                _ = await reconnectActiveMacIfAvailable(stackUserID: identityProvider?.currentUserID)
            }
            return
        }
        if let pairedMacStore, !device.deviceId.hasPrefix("manual-") {
            do {
                try await pairedMacStore.upsert(
                    macDeviceID: device.deviceId,
                    displayName: device.displayName,
                    routes: instance.routes,
                    markActive: true,
                    stackUserID: identityProvider?.currentUserID
                )
                hasKnownPairedMac = true
            } catch {
                mobileShellLog.error(
                    "connectToRegistryInstance upsert failed device=\(device.deviceId, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
            }
        }
        await loadPairedMacs()
        await loadRegistryDevices()
    }

    /// Reload ``pairedMacs`` from the store, scoped to the signed-in Stack user.
    ///
    /// A missing current Stack user id yields no pairings rather than falling
    /// back to the unscoped all-users query, so a shared device never exposes
    /// another user's Macs in the switcher.
    public func loadPairedMacs() async {
        guard let pairedMacStore, isSignedIn,
              let stackUserID = identityProvider?.currentUserID else {
            pairedMacs = []
            return
        }
        let loaded: [MobilePairedMac]
        do {
            loaded = try await pairedMacStore.loadAll(stackUserID: stackUserID)
        } catch {
            mobileShellLog.error("paired mac store loadAll failed: \(String(describing: error), privacy: .public)")
            return
        }
        // The await above suspended the main actor; a sign-out or user switch may
        // have run meanwhile. Discard the result unless we are still the same
        // signed-in user, so a slow load can never repopulate another user's hosts.
        guard isSignedIn, identityProvider?.currentUserID == stackUserID else {
            pairedMacs = []
            return
        }
        pairedMacs = loaded
    }

    /// Switch the live connection to `macDeviceID`, persisting it as the active
    /// pairing only on a successful connect.
    ///
    /// The underlying connect path is destructive (it replaces the live client),
    /// so a failed switch to an offline/stale Mac would drop the working session.
    /// To avoid stranding the user, the store's active row is only updated on a
    /// successful connect, and on failure the previously-active Mac (still the
    /// active row) is reconnected. A no-op when already connected to that Mac.
    /// - Parameter macDeviceID: The stored Mac to switch to.
    public func switchToMac(macDeviceID: String) async {
        guard let pairedMacStore,
              let target = pairedMacs.first(where: { $0.macDeviceID == macDeviceID }) else { return }
        if target.isActive, connectionState == .connected { return }
        // The currently-active Mac to fall back to if the switch fails.
        let previousActive = pairedMacs.first { $0.isActive && $0.macDeviceID != macDeviceID }
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        guard let (host, port) = Self.firstReconnectHostPortRoute(
            target.routes,
            supportedKinds: supportedKinds
        ), let normalizedHost = MobileShellRouteAuthPolicy.normalizedManualHost(host) else {
            mobileShellLog.error("switchToMac: no reconnectable route mac=\(macDeviceID, privacy: .public)")
            return
        }
        await connectManualHost(name: target.displayName ?? host, host: host, port: port)
        // Persist the active row only if the live connection is to THIS Mac's
        // route. A different switch tapped while this connect was in flight
        // supersedes it via `beginPairingAttempt`, leaving `connectionState`
        // `.connected` for the other Mac; matching the live route prevents this
        // superseded task from persisting a stale active target.
        if connectionState == .connected,
           case let .hostPort(liveHost, livePort)? = activeRoute?.endpoint,
           liveHost == normalizedHost, livePort == port {
            do {
                try await pairedMacStore.setActive(macDeviceID: macDeviceID)
            } catch {
                mobileShellLog.error("paired mac store setActive failed mac=\(macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        } else if previousActive != nil, connectionState != .connected {
            // The switch did not connect and the destructive connect path dropped
            // the previous session; reconnect to the still-active previous Mac so
            // the user is not left stranded on a failed switch.
            _ = await reconnectActiveMacIfAvailable(stackUserID: identityProvider?.currentUserID)
        }
        await loadPairedMacs()
    }

    /// Forget `macDeviceID`. Always removes the selected stored row by its real
    /// id, and additionally tears down the live connection when that row is the
    /// active one (the live attach ticket can carry a transient manual id, so we
    /// must not rely on it to identify the row being forgotten).
    /// - Parameter macDeviceID: The stored Mac to forget.
    public func forgetMac(macDeviceID: String) async {
        let isActiveMac = pairedMacs.first(where: { $0.macDeviceID == macDeviceID })?.isActive ?? false
        if isActiveMac, connectionState == .connected {
            disconnectLiveConnection()
        }
        do {
            try await pairedMacStore?.remove(macDeviceID: macDeviceID)
        } catch {
            mobileShellLog.error("paired mac store remove failed mac=\(macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
        await loadPairedMacs()
    }

    static func firstReconnectHostPortRoute(
        _ routes: [CmxAttachRoute],
        supportedKinds: [CmxAttachTransportKind]
    ) -> (String, Int)? {
        let supportedKinds = Set(supportedKinds)
        for route in routes.sorted(by: routeSortsBefore) {
            if !supportedKinds.isEmpty, !supportedKinds.contains(route.kind) {
                continue
            }
            if case let .hostPort(host, port) = route.endpoint {
                return (host, port)
            }
        }
        return nil
    }

    /// Runs one paired-Mac store mutation on the serialized write chain.
    ///
    /// All `markActive` writes go through here so they execute strictly in
    /// submission order, and `ifStillCurrent` is re-evaluated at EXECUTION
    /// time (after every earlier write has fully landed), not at submission.
    /// That closes the check-then-await race: a stale status-adoption task
    /// either observes it lost currency and skips, or it is still current
    /// and any newer connection's write is queued strictly behind it and
    /// overwrites the active mark. The chain is deliberately not cancelled
    /// on disconnect; in-flight writes complete or skip via their own check.
    private func performSerializedPairedMacWrite(
        ifStillCurrent: (() -> Bool)?,
        _ operation: @escaping @MainActor () async -> Void
    ) async {
        let previous = pairedMacWriteChain
        let task = Task { @MainActor in
            await previous?.value
            if let ifStillCurrent, !ifStillCurrent() { return }
            await operation()
        }
        pairedMacWriteChain = task
        await task.value
    }

    /// Persists `ticket` as the active paired Mac.
    ///
    /// The write runs on the serialized paired-Mac chain. The status-driven
    /// identity adoption passes `ifStillCurrent` so a stale reply cannot
    /// commit `markActive: true` for an old Mac after the user has started
    /// pairing a new one; the connect path leaves it `nil` (its write is for
    /// the connection it just established).
    private func persistPairedMacFromTicket(
        _ ticket: CmxAttachTicket,
        ifStillCurrent: (() -> Bool)? = nil
    ) async {
        guard let pairedMacStore else { return }
        guard !ticket.macDeviceID.isEmpty else { return }
        // Strip routes that we can't reconnect to without server-side state
        // (manual-workspace routes have no real macDeviceID and aren't useful).
        guard ticket.macDeviceID != "manual-ticket-request",
              !ticket.macDeviceID.hasPrefix("manual-") else { return }
        let stackUserID = identityProvider?.currentUserID
        // The compact pairing QR carries no display name; the name arrives
        // post-handshake via `mobile.host.status`. Until it does, keep any
        // name we already know for this Mac instead of clobbering it with
        // nil (the store's upsert overwrites the column unconditionally).
        // The lookup runs inside the serialized write chain so it cannot
        // read a name that a queued fresher write is about to replace, and
        // it prefers the current user's record for this Mac before falling
        // back to any account's record stored on this device.
        let ticketDisplayName = ticket.macDisplayName
        await performSerializedPairedMacWrite(ifStillCurrent: ifStillCurrent) { [weak self] in
            guard let self else { return }
            var displayName = ticketDisplayName
            if displayName == nil {
                let knownMacs = (try? await pairedMacStore.loadAll(stackUserID: nil)) ?? []
                let matches = knownMacs.filter { $0.macDeviceID == ticket.macDeviceID }
                displayName = (matches.first { $0.stackUserID == stackUserID } ?? matches.first)?
                    .displayName
            }
            do {
                try await pairedMacStore.upsert(
                    macDeviceID: ticket.macDeviceID,
                    displayName: displayName,
                    routes: ticket.routes,
                    markActive: true,
                    stackUserID: stackUserID
                )
                // A real, reconnectable Mac is now the active paired Mac: record
                // the persisted hint so the next launch shows RestoringSessionView
                // during the reconnect window instead of the empty add-device sheet.
                self.hasKnownPairedMac = true
            } catch {
                mobileShellLog.error("paired mac store upsert failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Recovers the Mac's identity for a connection whose ticket arrived
    /// without a device id (the minimal v2 pairing QR), as its own
    /// `mobile.host.status` request with the default RPC timeout.
    ///
    /// Identity recovery must not depend on the terminal-output capability
    /// probe's 750ms best-effort timeout: the probe is allowed to fail fast
    /// (the terminal just falls back to raw bytes), but the status report is
    /// the ONLY path that persists a freshly QR-paired Mac, so a slow tailnet
    /// link that times the probe out must not cost the paired-Mac record and
    /// reconnect-on-launch. The probe applies identity itself when it
    /// succeeds (no extra request in the common case) and calls this when it
    /// cannot, so the recovery request runs with the full RPC timeout. Both
    /// feed the same guarded
    /// ``applyHostReportedIdentity(client:deviceID:displayName:)`` path.
    private func scheduleHostIdentityAdoptionIfNeeded(client: MobileCoreRPCClient) {
        guard activeTicket?.macDeviceID.isEmpty == true else { return }
        hostIdentityAdoptionTask?.cancel()
        hostIdentityAdoptionTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.remoteClient === client else { return }
            let data: Data
            do {
                data = try await client.sendRequest(
                    MobileCoreRPCClient.requestData(method: "mobile.host.status", params: [:])
                )
            } catch {
                // The connection (or a reconnect) re-schedules adoption; a
                // failed status here means the connection itself is in
                // trouble and its own recovery paths take over.
                mobileShellLog.error("host identity status request failed: \(String(describing: error), privacy: .private)")
                return
            }
            guard !Task.isCancelled,
                  let payload = try? MobileHostStatusResponse.decode(data) else { return }
            await self.applyHostReportedIdentity(
                client: client,
                deviceID: payload.macDeviceID,
                displayName: payload.macDisplayName
            )
        }
    }

    /// Adopts the identity (`mac_device_id`, `mac_display_name`) reported by
    /// `mobile.host.status`. The minimal pairing QR carries neither, so this
    /// post-handshake report is what makes a QR-paired Mac identifiable: the
    /// device id keys the paired-Mac record (launch reconnect, host switcher)
    /// and the name replaces the placeholder in the UI.
    ///
    /// `client` is the connection the status reply belongs to. Every state
    /// read/mutation re-checks `remoteClient === client` after a suspension,
    /// so a stale reply (the user re-paired while the request was in flight)
    /// can never adopt the OLD Mac's identity onto the NEW connection's
    /// empty-id ticket or persist a mixed paired-Mac record.
    private func applyHostReportedIdentity(
        client: MobileCoreRPCClient,
        deviceID: String?,
        displayName: String?
    ) async {
        guard remoteClient === client else { return }
        if let reportedID = deviceID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reportedID.isEmpty,
           let ticket = activeTicket,
           ticket.macDeviceID.isEmpty,
           let adopted = try? CmxAttachTicket(
               version: ticket.version,
               workspaceID: ticket.workspaceID,
               terminalID: ticket.terminalID,
               macDeviceID: reportedID,
               macDisplayName: ticket.macDisplayName,
               macUserEmail: ticket.macUserEmail,
               macUserID: ticket.macUserID,
               macPairingCompatibilityVersion: ticket.macPairingCompatibilityVersion,
               macAppVersion: ticket.macAppVersion,
               macAppBuild: ticket.macAppBuild,
               routes: ticket.routes,
               expiresAt: ticket.expiresAt,
               authToken: ticket.authToken
           ) {
            activeTicket = adopted
            // The connection is now attributable to a real Mac: persist it so
            // reconnect-on-launch and the host switcher have a record (the
            // empty-id ticket was skipped by the connect-time persist).
            await persistPairedMacFromTicket(
                adopted,
                ifStillCurrent: { [weak self] in self?.remoteClient === client }
            )
        }
        guard remoteClient === client else { return }
        await applyHostReportedDisplayName(
            displayName,
            ifStillCurrent: { [weak self] in self?.remoteClient === client }
        )
    }

    /// Adopts the Mac name reported by `mobile.host.status`. The pairing QR
    /// no longer carries the name, so this post-handshake report is what
    /// replaces the placeholder in the UI and fills in the paired-Mac store
    /// for freshly paired Macs. The caller has verified the reply belongs to
    /// the current connection; `ticket` is captured once here so the store
    /// write stays internally consistent, and `ifStillCurrent` is re-checked
    /// immediately before that write so a connection change during the name
    /// application cannot mark a stale Mac active.
    private func applyHostReportedDisplayName(
        _ reportedName: String?,
        ifStillCurrent: (() -> Bool)? = nil
    ) async {
        guard let name = reportedName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              let ticket = activeTicket else {
            return
        }
        // The host's report is fresher than whatever the ticket carried (it
        // reflects the Mac-side pairing-name setting, including renames), so
        // it always wins over the device-id placeholder or a stale name.
        connectedHostName = name
        guard let pairedMacStore,
              !ticket.macDeviceID.isEmpty,
              ticket.macDeviceID != "manual-ticket-request",
              !ticket.macDeviceID.hasPrefix("manual-") else {
            return
        }
        let stackUserID = identityProvider?.currentUserID
        await performSerializedPairedMacWrite(ifStillCurrent: ifStillCurrent) {
            do {
                try await pairedMacStore.upsert(
                    macDeviceID: ticket.macDeviceID,
                    displayName: name,
                    routes: ticket.routes,
                    markActive: true,
                    stackUserID: stackUserID
                )
            } catch {
                mobileShellLog.error("paired mac display-name upsert failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// `true` on a physical iPhone/iPad; `false` in the simulator and in
    /// macOS-hosted package tests. Drives the loopback-pairing rejection:
    /// the simulator's 127.0.0.1 is the host Mac and dev auto-pair depends
    /// on it, while a physical device dialing loopback only ever reaches
    /// itself.
    private static var isPhysicalDevice: Bool {
        #if os(iOS) && !targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    private static func manualHostRoute(host: String, port: Int) throws -> CmxAttachRoute {
        let routeKind = MobileShellRouteAuthPolicy.manualRouteKind(for: host)
        return try CmxAttachRoute(
            id: routeKind.rawValue,
            kind: routeKind,
            endpoint: .hostPort(host: host, port: port)
        )
    }

    @discardableResult
    public func connectPairingURL(_ rawValue: String? = nil) async -> Bool {
        await connectPairingURLResult(rawValue).didConnect
    }

    @discardableResult
    public func connectPairingURLResult(_ rawValue: String? = nil) async -> MobilePairingURLConnectionResult {
        await connectPairingURLResult(rawValue, acceptedVersionWarning: false)
    }

    @discardableResult
    private func connectPairingURLResult(
        _ rawValue: String? = nil,
        acceptedVersionWarning: Bool
    ) async -> MobilePairingURLConnectionResult {
        let rawURL = Self.normalizedPairingURL(rawValue ?? pairingCode)
        _ = beginPairingValidationAttempt()
        connectionAttemptGeneration = UUID()
        if connectionState != .connected {
            clearActiveConnectionContext()
            macConnectionStatus = .unavailable
            replaceRemoteClient(with: nil)
        }
        clearPairingError()
        clearPairingVersionWarning()
        let ticket: CmxAttachTicket
        do {
            ticket = try CmxAttachTicketInput.decode(rawURL)
            // The v2 grammar rejects loopback inside the decoder; the legacy
            // grammars must keep decoding loopback for the simulator dev flow
            // (where 127.0.0.1 IS the host Mac). On a physical phone no
            // grammar may pair to loopback: the route would dial the phone
            // itself, and loopback is Stack-auth-trusted, so the bearer token
            // would be handed to whatever local process answers. Pure policy,
            // unit tested for both device values; only this wiring is
            // compile-time.
            if MobileShellRouteAuthPolicy.ticketRejectsLoopbackRoutes(
                ticket.routes,
                isPhysicalDevice: Self.isPhysicalDevice
            ) {
                throw MobileSyncPairingPayloadError.loopbackRouteRejected
            }
        } catch {
            if case MobileSyncPairingPayloadError.loopbackRouteRejected = error {
                // A scanned/pasted code that only points back at the Mac
                // itself (127.0.0.1) would make the phone dial itself. Name
                // the actual fix (Tailscale on the Mac) instead of the
                // generic invalid-code copy.
                applyPairingValidationFailure(.loopbackRejected)
            } else {
                applyPairingValidationFailure(.invalidCode)
            }
            if connectionState != .connected {
                connectionState = .disconnected
                macConnectionStatus = .unavailable
                clearRemoteConnectionContext()
            }
            return .failed
        }

        if let emailFailure = Self.emailFailure(
            for: ticket,
            actualUserID: identityProvider?.currentUserID,
            actualEmail: identityProvider?.currentUserEmail
        ) {
            applyPairingValidationFailure(emailFailure)
            if connectionState != .connected {
                connectionState = .disconnected
                macConnectionStatus = .unavailable
                clearRemoteConnectionContext()
            }
            return .failed
        }

        if !acceptedVersionWarning,
           let warning = versionWarning(for: ticket) {
            pendingPairingVersionWarningURL = rawURL
            pairingVersionWarning = warning
            return .needsUserApproval
        }

        let attemptID = beginPairingAttempt(method: "qr")

        // Offline preflight: fail fast instead of stacking per-route connect
        // timeouts into the opaque ~60s wait. Skipped only when no route is
        // dialable so `connect()` classifies that as `no_supported_route`.
        // Ticket expiry deliberately does NOT gate this: a stale QR is a valid
        // pairing input now (expiry is enforced solely where the RPC attach
        // token is used), so an expired legacy code scanned offline must say
        // "offline", not crawl the route loop's stacked timeouts.
        let candidateRoutes = Self.supportedRoutes(for: ticket, supportedKinds: runtime?.supportedRouteKinds ?? [])
        if !candidateRoutes.isEmpty {
            switch await failPairingIfOffline(attemptID: attemptID, phase: "preflight", routes: candidateRoutes) {
            case .failedOffline: return .failed
            case .superseded: return .superseded
            case .proceed: break
            }
        }

        do {
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            let noThrowFailure = try await connect(ticket: ticket)
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            if connectionState == .connected && activeTicket != nil {
                recordPairingSucceeded()
                return .connected
            }
            // `connect()` returned without connecting and already set a
            // specific error; record without overwriting that message.
            recordFailureForCurrentConnectionError(phase: "connect", category: noThrowFailure)
            return .failed
        } catch is CancellationError {
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
            return .failed
        } catch {
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            mobileShellLog.error("pairing failed: \(String(describing: error), privacy: .private)")
            // Definitive auth failures drive the re-auth prompt rather than a
            // generic connection error (matches the manual-host path); the
            // helper records the analytics failure + guidance.
            if disconnectForAuthorizationFailureIfNeeded(error) { return .failed }
            let category = MobilePairingFailureCategory.classify(error: error, route: activeRoute)
            applyPairingFailure(category, phase: "connect")
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
            return .failed
        }
    }

    public func cancelPairing() {
        invalidatePairingAttempt()
        clearPairingError()
        if pairingVersionWarning != nil || pendingPairingVersionWarningURL != nil {
            clearPairingVersionWarning()
            return
        }
        clearPairingVersionWarning()
        connectionState = .disconnected
        macConnectionStatus = .unavailable
        clearRemoteConnectionContext()
    }

    /// Accepts the pending version mismatch warning and retries the stored pairing URL.
    ///
    /// Returns the retry result so the UI can clear temporary attach-ticket
    /// authentication only after the accepted pairing flow reaches a terminal
    /// state.
    @discardableResult
    public func acceptPairingVersionWarning() async -> MobilePairingURLConnectionResult {
        guard let rawURL = pendingPairingVersionWarningURL else {
            clearPairingVersionWarning()
            return .failed
        }
        clearPairingVersionWarning()
        return await connectPairingURLResult(rawURL, acceptedVersionWarning: true)
    }

    /// Tear down the live connection and reset connection UI state, without
    /// touching the paired-Mac store or the restoring-gate hint. The switcher's
    /// ``forgetMac(macDeviceID:)`` and ``switchToMac(macDeviceID:)`` reuse this,
    /// so it must not clear ``hasKnownPairedMac`` (that belongs to the explicit
    /// forget-active path below).
    private func disconnectLiveConnection() {
        suppressNextConnectionOutageEdge = true
        invalidatePairingAttempt()
        clearPairingError()
        connectionRequiresReauth = false
        connectionState = .disconnected
        macConnectionStatus = .unavailable
        clearRemoteConnectionContext()
    }

    /// Disconnect from the currently paired Mac and forget it so the next
    /// session starts from a fresh QR scan. Clears in-memory state and the
    /// persisted active flag (other macs in SQLite stay, but none are marked
    /// active so reconnect-on-launch is a no-op until the user pairs again).
    /// Backs the "Rescan QR" action.
    public func disconnectAndForgetActiveMac() {
        let staleMacID = activeTicket?.macDeviceID
        disconnectLiveConnection()
        // Forgetting the active Mac clears the restoring hint so the next launch
        // (and the current disconnected view) shows add-device immediately. Bump
        // the reconnect generation first so an in-flight reconnect can't re-set the
        // hint or the gate flags after the user forgot the Mac.
        storedMacReconnectGeneration &+= 1
        hasKnownPairedMac = false
        isReconnectingStoredMac = false
        didFinishStoredMacReconnectAttempt = false
        if let pairedMacStore, let macID = staleMacID {
            // Fire-and-forget: forgetting the persisted mac is cleanup that must
            // not block the synchronous disconnect UI state update above.
            Task {
                do {
                    try await pairedMacStore.remove(macDeviceID: macID)
                } catch {
                    mobileShellLog.error("forgetActiveMac removal failed: \(String(describing: error), privacy: .private)")
                }
            }
        }
    }

    private static func normalizedPairingURL(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("cmux-ios://") else {
            return trimmed
        }
        let scalars = trimmed.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private func manualHostTicket(name: String, host: String, port: Int) async throws -> CmxAttachTicket {
        let directRoute = try Self.manualHostRoute(host: host, port: port)
        let displayName = name.isEmpty ? host : name
        if MobileShellRouteAuthPolicy.routeAllowsStackAuth(directRoute) {
            do {
                let ticket = try await requestManualAttachTicket(
                    route: directRoute,
                    displayName: displayName
                )
                return ticket
            } catch {
                guard Self.shouldFallbackToSyntheticManualTicket(after: error) else {
                    throw error
                }
            }
            return try Self.manualHostTicket(
                displayName: displayName,
                macDeviceID: "manual-\(host):\(port)",
                route: directRoute
            )
        }
        return try Self.manualHostTicket(
            displayName: displayName,
            macDeviceID: "manual-\(host):\(port)",
            route: directRoute
        )
    }

    private static func shouldFallbackToSyntheticManualTicket(after error: any Error) -> Bool {
        guard case let MobileShellConnectionError.rpcError(code, message) = error else {
            return false
        }
        let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let normalizedCode,
           ["method_not_found", "not_found", "unknown_method", "unsupported_method"].contains(normalizedCode) {
            return true
        }
        return normalizedMessage.contains("unknown method")
            || normalizedMessage.contains("method not found")
            || normalizedMessage.contains("unsupported method")
            || normalizedMessage.contains("ticket unavailable")
            || normalizedMessage.contains("ticket not available")
    }

    private static func manualHostTicket(
        displayName: String,
        macDeviceID: String,
        route: CmxAttachRoute
    ) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: "manual-workspace",
            terminalID: nil,
            macDeviceID: macDeviceID,
            macDisplayName: displayName,
            routes: [route],
            expiresAt: Date().addingTimeInterval(60 * 60)
        )
    }

    private func requestManualAttachTicket(
        route: CmxAttachRoute,
        displayName: String
    ) async throws -> CmxAttachTicket {
        guard let runtime else {
            throw MobileShellConnectionError.insecureManualRoute
        }
        let probeTicket = try Self.manualHostTicket(
            displayName: displayName,
            macDeviceID: "manual-ticket-request",
            route: route
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: probeTicket,
            allowsStackAuthFallback: true
        )
        let resultData = try await client.sendRequest(
            MobileCoreRPCClient.requestData(
                method: "mobile.attach_ticket.create",
                params: [
                    "ttl_seconds": 3600,
                    "scope": "mac",
                ]
            ),
            timeoutNanoseconds: runtime.pairingRequestTimeoutNanoseconds
        )
        let response = try MobileManualAttachTicketCreateResponse.decode(resultData)
        return try response.ticket.constrainingRoutes(to: [route], fallbackDisplayName: displayName)
    }

    public func createWorkspace() {
        guard remoteClient == nil else {
            guard createWorkspaceTask == nil else { return }
            let taskID = UUID()
            createWorkspaceTaskID = taskID
            createWorkspaceTask = Task { @MainActor [weak self] in
                defer { self?.clearCreateWorkspaceTask(id: taskID) }
                guard let self else { return }
                await self.createRemoteWorkspace()
            }
            return
        }
        let nextIndex = workspaces.count + 1
        let workspace = MobileWorkspacePreview(
            id: .init(rawValue: "workspace-\(nextIndex)"),
            name: L10n.workspaceName(index: nextIndex),
            terminals: [
                MobileTerminalPreview(
                    id: .init(rawValue: "workspace-\(nextIndex)-terminal-1"),
                    name: L10n.terminalName(index: 1)
                ),
            ]
        )
        workspaces.append(workspace)
        selectedWorkspaceID = workspace.id
        selectedTerminalID = workspace.terminals.first?.id
        suppressTerminalAutoFocusOnNextAttach(for: selectedTerminalID)
    }

    /// Creates a terminal in `workspaceID`, or the selected workspace when nil.
    ///
    /// Callers that act on a specific workspace (e.g. the "+" button on a
    /// workspace row) should pass its id so an in-flight create can't land in a
    /// different workspace if the selection drifts before the async work runs.
    public func createTerminal(in workspaceID: MobileWorkspacePreview.ID? = nil) {
        let targetWorkspaceID = workspaceID ?? selectedWorkspace?.id
        guard remoteClient == nil else {
            // Bail BEFORE pinning selection when a create is already in flight,
            // so a second "+" on another workspace can't strand the UI on that
            // workspace with no new terminal while the earlier RPC still runs.
            guard createTerminalTask == nil else { return }
            // Pin selection to the target so the async create + the resulting
            // terminal selection stay on the workspace the caller intended.
            if let targetWorkspaceID { selectedWorkspaceID = targetWorkspaceID }
            let taskID = UUID()
            createTerminalTaskID = taskID
            createTerminalTask = Task { @MainActor [weak self] in
                defer { self?.clearCreateTerminalTask(id: taskID) }
                guard let self else { return }
                await self.createRemoteTerminal(in: targetWorkspaceID)
            }
            return
        }
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == targetWorkspaceID }) else {
            return
        }
        selectedWorkspaceID = targetWorkspaceID
        let terminalIndex = workspaces[workspaceIndex].terminals.count + 1
        let terminal = MobileTerminalPreview(
            id: .init(rawValue: "\(workspaces[workspaceIndex].id.rawValue)-terminal-\(terminalIndex)"),
            name: L10n.terminalName(index: terminalIndex)
        )
        workspaces[workspaceIndex].terminals.append(terminal)
        selectedTerminalID = terminal.id
        suppressTerminalAutoFocusOnNextAttach(for: terminal.id)
    }

    public func selectTerminal(_ id: MobileTerminalPreview.ID?) {
        selectedTerminalID = id
    }

    /// One-shot "actually navigate" deep-link intent; API in
    /// `MobileShellComposite+DeeplinkNavigation.swift` (storage must live here).
    public internal(set) var deeplinkWorkspaceNavigationRequest: DeeplinkWorkspaceNavigationRequest?

    /// Selects `id` as a chrome action (the terminal picker), so the surface
    /// that comes up does not grab the keyboard.
    ///
    /// Switching terminals from the picker is a navigation intent, not a typing
    /// intent, so unlike ``selectTerminal(_:)`` (which a push-notification deep
    /// link uses and which is allowed to autofocus) this suppresses the target
    /// surface's next autofocus. Re-confirming the already-selected terminal is
    /// a no-op suppression, since no surface re-attach happens.
    public func selectTerminalFromChrome(_ id: MobileTerminalPreview.ID) {
        if id != selectedTerminalID {
            terminalAutoFocusSuppressedSurfaceIDs.insert(id.rawValue)
        }
        selectedTerminalID = id
    }

    /// Whether the surface for `terminalID` may grab the keyboard on its next
    /// window attach. False while a one-shot suppression is pending for it.
    public func shouldAutoFocusTerminalSurface(_ terminalID: String) -> Bool {
        !terminalAutoFocusSuppressedSurfaceIDs.contains(terminalID)
    }

    /// Clears the one-shot autofocus suppression for `terminalID` once its
    /// surface has mounted (and so has already attached with autofocus
    /// disabled). Called from the surface's `onAppear`.
    public func consumeTerminalAutoFocusSuppression(for terminalID: String) {
        terminalAutoFocusSuppressedSurfaceIDs.remove(terminalID)
    }

    /// Marks `terminalID` so its surface does not autofocus on its next window
    /// attach. Called by every create path the instant the new terminal becomes
    /// the selection, so a freshly created terminal never steals the keyboard.
    private func suppressTerminalAutoFocusOnNextAttach(for terminalID: MobileTerminalPreview.ID?) {
        guard let terminalID else { return }
        terminalAutoFocusSuppressedSurfaceIDs.insert(terminalID.rawValue)
    }

    public func reportTerminalViewport(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID,
        viewportSize: MobileTerminalViewportSize
    ) {
        let key = viewportKey(workspaceID: workspaceID, terminalID: terminalID)
        reportedViewportSizesByTerminalKey[key] = viewportSize
    }

    public func openWorkspace(_ id: MobileWorkspacePreview.ID) async {
        let workspace = workspaces.first { $0.id == id }
        analytics.capture("ios_workspace_opened", [
            "terminal_count": .int(workspace?.terminals.count ?? 0),
            "is_pinned": .bool(workspace?.isPinned ?? false),
            "source": .string("list_tap"),
        ])
        setSelectedWorkspaceID(id)
    }

    public func sendTerminalInput() {
        Task { @MainActor [weak self] in
            await self?.submitTerminalInput()
        }
    }

    public func submitTerminalInput() async {
        let text = terminalInputText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        terminalInputText = ""
        guard remoteClient != nil else { return }
        // North-star event. One per submit, never per keystroke. Sizes/counts
        // only — never the text itself (the call below ships the text; analytics
        // ships only its byte and line counts, mirroring the code's own
        // `byteCount` privacy:.public logging posture).
        analytics.capture("ios_terminal_input_submitted", [
            "byte_count": .int(text.utf8.count),
            "line_count": .int(text.split(separator: "\n", omittingEmptySubsequences: false).count),
            "had_attachment": .bool(false),
        ])
        await sendRemoteTerminalInput(text + "\r")
    }

    /// Show or hide the iMessage-style composer from the input accessory bar.
    ///
    /// With the composer open by default, the OPEN branch is reached only after
    /// the user explicitly dismissed it on this terminal and tapped compose again
    /// — an unambiguous "I want to compose" intent, so it also requests field
    /// focus (the default-open presentation deliberately does not).
    /// - Parameter terminalID: The terminal whose composer the caller is acting
    ///   on (the surface's own id). The focus handshake is keyed to it so the
    ///   composer view serving that terminal — and only it — consumes the
    ///   request. `nil` falls back to the selected terminal; the rendered
    ///   terminal can diverge from the selection (the detail view falls back to
    ///   the workspace's first terminal), so callers that know their surface
    ///   should always pass it.
    public func toggleComposer(forTerminalID terminalID: String? = nil) {
        if isComposerPresented {
            setComposerPresented(false)
        } else {
            setComposerPresented(true)
            requestComposerFieldFocus(forTerminalID: terminalID)
        }
    }

    /// Ensure the composer is presented and ask its field to take focus, without ever
    /// dismissing it.
    ///
    /// Drives the reveal-and-focus path: the surface invokes this when the user taps
    /// the compose button (or reveals the chrome) while a composer is already
    /// logically presented but suppressed or unfocused. The presented state is only
    /// ever raised here (never dismissed), so a still-presented composer and its
    /// draft are preserved; the focus token is always bumped so the field re-focuses
    /// even when the presented flag did not change.
    /// - Parameter terminalID: The terminal whose composer should take focus
    ///   (the requesting surface's own id); `nil` falls back to the selected
    ///   terminal. See ``toggleComposer(forTerminalID:)`` for why the explicit
    ///   id matters.
    public func presentAndFocusComposer(forTerminalID terminalID: String? = nil) {
        setComposerPresented(true)
        requestComposerFieldFocus(forTerminalID: terminalID)
    }

    /// Explicitly dismiss the iMessage-style composer for the selected terminal,
    /// recording the dismissal for the session. This is the explicit-close API
    /// (hosts and tests); the user-facing closes go through ``toggleComposer()``.
    /// The keyboard collapsing never dismisses the composer (Round 8): the band
    /// survives a keyboard-down and only the chevron / compose toggle closes it.
    /// Idempotent: a no-op when the composer is already closed.
    public func dismissComposer() {
        guard isComposerPresented else { return }
        setComposerPresented(false)
    }

    /// Mirror of the composer field's `@FocusState`, reported by
    /// ``TerminalComposerView`` on every focus change. See
    /// ``composerFieldIsFocused`` for what reads it.
    public func composerFieldFocusChanged(_ focused: Bool) {
        composerFieldIsFocused = focused
    }

    /// Consume the one-shot "focus the composer field" handshake for the
    /// composer serving `terminalID`, returning whether a pending request
    /// targeted that terminal. The composer view calls this from `onAppear` (a
    /// mount that follows an explicit open or a mid-compose terminal switch)
    /// and from its `onChange` of ``composerFocusRequest`` (a bump while
    /// already mounted), so a request is honored exactly once and a later
    /// default-open remount never re-pops the keyboard.
    ///
    /// Keyed on the target terminal: during a terminal switch the outgoing
    /// composer view is still mounted and observes the same token bump, so a
    /// mismatched consume returns `false` and leaves the request armed for the
    /// incoming terminal's mount.
    public func consumePendingComposerFocusRequest(for terminalID: String) -> Bool {
        guard composerFocusRequestPending, composerFocusRequestTerminalID == terminalID else {
            return false
        }
        composerFocusRequestPending = false
        composerFocusRequestTerminalID = nil
        return true
    }

    /// Ask the composer field to take focus: bump the token the mounted view
    /// observes and arm the pending flag a not-yet-mounted view consumes on
    /// appear, keyed to `terminalID` (`nil` = the currently selected terminal).
    /// Callers acting on a concrete surface pass that surface's id so the
    /// request always matches the composer view that will consume it, even
    /// when the rendered terminal and the store selection diverge.
    private func requestComposerFieldFocus(forTerminalID terminalID: String? = nil) {
        composerFocusRequest &+= 1
        composerFocusRequestPending = true
        composerFocusRequestTerminalID = terminalID ?? selectedTerminalID?.rawValue
    }

    /// Single mutation path for the per-terminal presented state (the dismissed
    /// set): both explicit transitions land here so the DEBUG diagnostic records
    /// every flag change, exactly like the old stored property's `didSet`. A
    /// no-op without a selected terminal (there is nothing to compose to) or
    /// when the state already matches.
    private func setComposerPresented(_ presented: Bool) {
        guard let terminalID = selectedTerminalID?.rawValue,
              presented != isComposerPresented else { return }
        if presented {
            composerDismissedTerminalIDs.remove(terminalID)
        } else {
            composerDismissedTerminalIDs.insert(terminalID)
            // The band (and its field) unmounts with the dismissal; the dying
            // field does not reliably deliver a final unfocus change, so clear
            // the mirror here to never leave a stale "field owns the keyboard".
            composerFieldIsFocused = false
        }
        #if DEBUG
        // COMPOSER: record every flag change (mutated by `toggleComposer`,
        // `dismissComposer`, and `presentAndFocusComposer`). An unexpected
        // `a == 0` during a bare keyboard dismiss is the "flag toggled off"
        // cause of the disappearing draft.
        diagnosticLog?.record(DiagnosticEvent(
            .composerPresentedChanged,
            a: presented ? 1 : 0
        ))
        #endif
    }

    /// Submit the composer's text to the selected terminal as a bracketed paste
    /// plus a single Return, then clear the field while keeping the composer
    /// open. Unlike ``submitTerminalInput()``, this delivers a multi-line block
    /// as one paste + one submit (via `terminal.paste`) so interior newlines do
    /// not fragment into multiple submissions in a TUI agent.
    ///
    /// The field is cleared only after the Mac acknowledges the paste. If the
    /// send fails (no connection, or an older host that does not implement
    /// `terminal.paste` and answers `method_not_found`), the composed text is
    /// kept so the user can retry instead of silently losing the message.
    public func submitComposerInput() async {
        let text = terminalInputText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard remoteClient != nil else { return }
        // Reject a re-entrant send (e.g. a double tap on Send) so the same text
        // is not pasted twice. The flag is set/cleared on the main actor around
        // the await, so no second call can slip past it.
        guard !isSubmittingComposerInput else { return }
        isSubmittingComposerInput = true
        defer { isSubmittingComposerInput = false }
        // Capture which terminal this text is for: if the user switches terminals
        // while the ack is in flight, the switch persists the outgoing text as the
        // SUBMITTED terminal's draft, and the sent text must be cleared from that
        // key, not from whatever terminal is selected when the ack returns.
        let submittedTerminalID = selectedTerminalID
        let sent = await sendRemoteTerminalPaste(text, submitKey: "return")
        guard sent else { return }
        await reconcileComposerDraftAfterSend(sentText: text, submittedTerminalID: submittedTerminalID)
    }

    /// Clear the sent text from wherever it now lives after a successful
    /// composer send: the visible field when the submitted terminal is still
    /// selected, or the submitted terminal's STORED draft when the user switched
    /// terminals while the ack was in flight (the switch persists the outgoing
    /// text under the submitted terminal's key, and without this it would
    /// resurrect on switch-back and invite a duplicate submission). In both
    /// places the clear is conditional on the value still being exactly the sent
    /// text, so anything newer the user typed is never discarded.
    ///
    /// Internal (not private) so tests can drive the post-ack reconciliation
    /// directly with a controlled draft store and selection.
    func reconcileComposerDraftAfterSend(
        sentText: String,
        submittedTerminalID: MobileTerminalPreview.ID?
    ) async {
        if selectedTerminalID == submittedTerminalID {
            // Only clear if the field still holds exactly what we sent, so a value
            // the user typed while the send was in flight is not discarded. The
            // field's `didSet` persists the clear, removing the stored draft too.
            if terminalInputText == sentText {
                terminalInputText = ""
            }
        } else if let submittedTerminalID, let draftStore {
            // Selection moved mid-flight. Clear the submitted terminal's stored
            // draft only when it is still exactly the sent text, so a newer draft
            // (typed after Send, before the switch) is preserved. Enqueued (and
            // awaited) on the FIFO draft pipeline so the check runs after the
            // terminal switch's own save of the outgoing text, and the
            // check-then-clear pair is atomic with respect to other operations.
            let terminalID = submittedTerminalID.rawValue
            let sent = sentText
            await enqueueDraftOperation {
                if await draftStore.draft(forTerminalID: terminalID) == sent {
                    await draftStore.clearDraft(forTerminalID: terminalID)
                }
            }.value
            // The user may have switched back during the awaits and had the sent
            // text restored into the field; clear that too so already-sent text
            // never resurrects.
            if selectedTerminalID == submittedTerminalID, terminalInputText == sentText {
                terminalInputText = ""
            }
        }
    }

    public func sendTerminalRawInput(_ text: String) {
        #if DEBUG
        mobileShellLog.debug("enqueue raw terminal input byteCount=\(text.utf8.count, privacy: .public)")
        #endif
        guard let workspaceID = selectedWorkspace?.id,
              let terminalID = selectedTerminalID else {
            #if DEBUG
            mobileShellLog.info("skip raw terminal input enqueue selectedWorkspace=\(self.selectedWorkspace == nil ? 0 : 1, privacy: .public) selectedTerminal=\(self.selectedTerminalID == nil ? 0 : 1, privacy: .public)")
            #endif
            return
        }
        switch rawTerminalInputBuffer.enqueue(
            text,
            workspaceID: workspaceID,
            terminalID: terminalID
        ) {
        case .startDraining:
            Task { @MainActor [weak self] in
                await self?.drainRawTerminalInputBuffer()
            }
        case .queued:
            return
        case .rejected:
            mobileShellLog.error("disconnecting mobile terminal input because pending byte count exceeded limit")
            // Real error-rate signal: the core input loop silently broke because
            // the send buffer filled. Distinct from an RPC timeout.
            analytics.capture("ios_terminal_input_dropped", [
                "pending_byte_count": .int(rawTerminalInputBuffer.pendingByteCount),
                "reason": .string("queue_full"),
            ])
            connectionError = L10n.string(
                "mobile.terminal.inputQueueFull",
                defaultValue: "The terminal can't accept more input right now. Wait a moment and retry, or reopen the terminal if it stays unavailable."
            )
            connectionErrorGuidance = nil
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
        }
    }

    public func submitTerminalRawInput(_ text: String) async {
        guard !text.isEmpty else { return }
        guard let workspaceID = selectedWorkspace?.id,
              let terminalID = selectedTerminalID else {
            return
        }
        await submitTerminalRawInput(text, workspaceID: workspaceID, terminalID: terminalID)
    }

    /// Raw-bytes overload. The libghostty render path on iOS uses this
    /// for input that may include binary sequences (mouse reports,
    /// kitty keyboard, IME byte streams). The wire RPC encodes bytes
    /// as the UTF-8-stringified payload of `mobile.terminal.input`,
    /// then the Mac decodes back to Data. If we ever need true binary
    /// fidelity (paste of mid-codepoint bytes, etc.), upgrade the
    /// `input` param to a base64 field.
    public func submitTerminalRawInput(_ data: Data, surfaceID: String) async {
        guard !data.isEmpty else { return }
        guard let text = String(data: data, encoding: .utf8) else {
            return
        }
        let workspaceCandidate = workspaces.first(where: { workspace in
            workspace.terminals.contains(where: { $0.id.rawValue == surfaceID })
        })
        guard let workspace = workspaceCandidate else { return }
        let terminalID = MobileTerminalPreview.ID(rawValue: surfaceID)
        await submitTerminalRawInput(text, workspaceID: workspace.id, terminalID: terminalID)
    }

    private func submitTerminalRawInput(
        _ text: String,
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) async {
        guard !text.isEmpty else { return }
        guard remoteClient != nil else { return }
        await sendRemoteTerminalInput(text, workspaceID: workspaceID, terminalID: terminalID)
    }

    private func drainRawTerminalInputBuffer() async {
        while let chunk = rawTerminalInputBuffer.nextBatch() {
            await submitTerminalRawInput(
                chunk.text,
                workspaceID: chunk.workspaceID,
                terminalID: chunk.terminalID
            )
        }
    }

    /// Establishes the live connection for `ticket`. Returns `nil` on success
    /// (and superseded-generation early exits), or the failure category it applied
    /// when it returned without connecting and without throwing
    /// (`.noSupportedRoute`), so callers record the matching analytics reason.
    @discardableResult
    private func connect(
        ticket: CmxAttachTicket,
        allowsStackAuthFallback: Bool? = nil
    ) async throws -> MobilePairingFailureCategory? {
        let generation = UUID()
        connectionAttemptGeneration = generation
        connectionGeneration = generation
        diagnosticLog?.record(DiagnosticEvent(.connect))
        cancelRemoteOperationTasks()
        rawTerminalInputBuffer.clear()
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        let supportedRoutes = Self.supportedRoutes(for: ticket, supportedKinds: supportedKinds)
        guard let firstRoute = supportedRoutes.first else {
            // No route kind this build can dial: set the specific category;
            // the caller records the matching analytics reason from it.
            connectionError = MobilePairingFailureCategory.noSupportedRoute.message
            connectionErrorGuidance = MobilePairingFailureCategory.noSupportedRoute.guidance
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
            return .noSupportedRoute
        }
        // No connect-time expiry gate: a pairing QR never expires (new QRs
        // carry no expiry at all), and the host authorizes by Stack account,
        // not ticket age. Expiry still gates the RPC-minted attach token at
        // its point of use (`MobileCoreRPCClient.requestDataWithAuth`).
        activeTicket = ticket
        activeRoute = firstRoute
        connectedHostName = placeholderHostName(for: ticket, firstRoute: firstRoute)
        replaceRemoteClient(with: nil)

        guard let runtime else {
            guard isCurrentConnectionAttempt(generation) else { return nil }
            clearPairingError()
            applyPreviewTicket(ticket, route: firstRoute)
            connectionState = .connected
            markMacConnectionHealthy()
            return nil
        }

        let workspaceListRequests = try Self.initialWorkspaceListRequests(for: ticket)
        // Stack auth is now the authorization gate for every request, so enable
        // it by default on any route trusted to carry the token (Tailscale,
        // loopback, LAN, .local). Untrusted manual public hosts stay off and
        // therefore cannot authorize, which is intended.
        let routeAllowsStackAuthFallback = allowsStackAuthFallback
            ?? supportedRoutes.allSatisfy(MobileShellRouteAuthPolicy.routeAllowsStackAuth)
        var lastError: (any Error)?
        for route in supportedRoutes {
            activeRoute = route
            mobileShellLog.info("pairing trying route kind=\(route.kind.rawValue, privacy: .public) endpoint=\(route.endpoint.logDescription, privacy: .private)")
            let client = MobileCoreRPCClient(
                runtime: runtime,
                route: route,
                ticket: ticket,
                allowsStackAuthFallback: routeAllowsStackAuthFallback
            )
            for workspaceListRequest in workspaceListRequests {
                do {
                    let resultData = try await client.sendRequest(
                        workspaceListRequest.data,
                        timeoutNanoseconds: runtime.pairingRequestTimeoutNanoseconds
                    )
                    let response = try MobileSyncWorkspaceListResponse.decode(resultData)
                    guard isCurrentConnectionAttempt(generation) else { return nil }
                    replaceRemoteClient(with: client)
                    startTerminalRefreshPolling()
                    // The connect seam guarantees identity recovery for an
                    // anonymous (v2 QR) ticket on every supported runtime, not
                    // just push-event ones: when the event-listener task starts,
                    // its status probe performs the recovery (one shared status
                    // request); when the runtime has no server-push events that
                    // task never runs, so recovery is scheduled directly here.
                    // Without this, pairing succeeded but the Mac was never
                    // persisted (no reconnect-on-launch, no host switcher entry).
                    // The schedule is a no-op for tickets that carry a device id.
                    if !(runtime.supportsServerPushEvents) {
                        scheduleHostIdentityAdoptionIfNeeded(client: client)
                    }
                    clearPairingError()
                    await persistPairedMacFromTicket(ticket)
                    applyRemoteWorkspaceList(response, preferActiveTicketTarget: workspaceListRequest.preferActiveTicketTarget)
                    syncSelectedTerminalForWorkspace()
                    connectionState = .connected
                    markMacConnectionHealthy()
                    diagnosticLog?.record(DiagnosticEvent(.pairOk))
                    if workspaceListRequest.isScoped {
                        scheduleFullWorkspaceListRefreshIfAvailable(
                            client: client,
                            route: route,
                            generation: generation
                        )
                    }
                    return nil
                } catch {
                    lastError = error
                    guard isCurrentConnectionAttempt(generation) else { return nil }
                    mobileShellLog.error(
                        "pairing route failed kind=\(route.kind.rawValue, privacy: .public) endpoint=\(route.endpoint.logDescription, privacy: .private) scoped=\(workspaceListRequest.isScoped ? 1 : 0, privacy: .public): \(String(describing: error), privacy: .private)"
                    )
                }
            }
        }

        clearRemoteConnectionContext()
        diagnosticLog?.record(DiagnosticEvent(.pairFail))
        throw lastError ?? MobileShellConnectionError.connectionClosed
    }

    private struct WorkspaceListRequest {
        var data: Data
        var isScoped: Bool
        var preferActiveTicketTarget: Bool
    }

    private static func supportedRoutes(
        for ticket: CmxAttachTicket,
        supportedKinds: [CmxAttachTransportKind]
    ) -> [CmxAttachRoute] {
        let orderedRoutes = ticket.routes.sorted(by: routeSortsBefore)
        guard !supportedKinds.isEmpty else {
            return orderedRoutes
        }
        let supportedKinds = Set(supportedKinds)
        return orderedRoutes.filter { route in
            supportedKinds.contains(route.kind)
        }
    }

    private static func attachTicketIsUnexpired(_ ticket: CmxAttachTicket, now: Date) -> Bool {
        !ticket.isExpired(at: now)
    }

    private static func initialWorkspaceListParams(for ticket: CmxAttachTicket) -> [String: Any] {
        guard UUID(uuidString: ticket.workspaceID) != nil else {
            return [:]
        }
        var params: [String: Any] = ["workspace_id": ticket.workspaceID]
        if let terminalID = ticket.terminalID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !terminalID.isEmpty {
            params["terminal_id"] = terminalID
        }
        return params
    }

    private static func initialWorkspaceListRequests(for ticket: CmxAttachTicket) throws -> [WorkspaceListRequest] {
        let scopedParams = initialWorkspaceListParams(for: ticket)
        let hasAttachToken = ticket.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        var requests: [WorkspaceListRequest] = []
        if hasAttachToken {
            requests.append(
                WorkspaceListRequest(
                    data: try MobileCoreRPCClient.requestData(method: "workspace.list", params: [:]),
                    isScoped: false,
                    preferActiveTicketTarget: true
                )
            )
        }

        if !scopedParams.isEmpty {
            requests.append(
                WorkspaceListRequest(
                    data: try MobileCoreRPCClient.requestData(method: "workspace.list", params: scopedParams),
                    isScoped: !scopedParams.isEmpty,
                    preferActiveTicketTarget: true
                )
            )
        }

        if requests.isEmpty {
            requests.append(
                WorkspaceListRequest(
                    data: try MobileCoreRPCClient.requestData(method: "workspace.list", params: [:]),
                    isScoped: false,
                    preferActiveTicketTarget: true
                )
            )
        }
        return requests
    }

    private func scheduleFullWorkspaceListRefreshIfAvailable(
        client: MobileCoreRPCClient,
        route: CmxAttachRoute,
        generation: UUID
    ) {
        guard workspaceListRefreshTask == nil else { return }
        workspaceListRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.workspaceListRefreshTask = nil }
            _ = await self.refreshAllWorkspacesWithAttachTokenIfAvailable(
                client: client,
                route: route,
                generation: generation,
                timeoutNanoseconds: self.runtime?.rpcRequestTimeoutNanoseconds
            )
        }
    }

    private func refreshAllWorkspacesWithAttachTokenIfAvailable(
        client: MobileCoreRPCClient,
        route: CmxAttachRoute,
        generation: UUID,
        timeoutNanoseconds: UInt64? = nil
    ) async -> Bool {
        guard MobileShellRouteAuthPolicy.routeAllowsStackAuth(route),
              let attachToken = activeTicket?.authToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !attachToken.isEmpty else {
            return false
        }
        do {
            let resultData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "workspace.list",
                    params: [:]
                ),
                timeoutNanoseconds: timeoutNanoseconds ?? runtime?.pairingRequestTimeoutNanoseconds
            )
            let response = try MobileSyncWorkspaceListResponse.decode(resultData)
            guard isCurrentRemoteConnection(client: client, generation: generation) else {
                return false
            }
            let activeTicketWorkspaceID = activeTicket.map { MobileWorkspacePreview.ID(rawValue: $0.workspaceID) }
            applyRemoteWorkspaceList(
                response,
                preferActiveTicketTarget: selectedWorkspaceID == nil || selectedWorkspaceID == activeTicketWorkspaceID
            )
            return true
        } catch {
            mobileShellLog.info("full mobile workspace list unavailable after scoped attach: \(String(describing: error), privacy: .private)")
            if isCurrentRemoteConnection(client: client, generation: generation) {
                _ = disconnectForAuthorizationFailureIfNeeded(error)
            }
            return false
        }
    }

    private func clearActiveConnectionContext() {
        activeTicket = nil
        activeRoute = nil
        connectedHostName = ""
    }

    private func clearRemoteConnectionContext() {
        connectionGeneration = UUID()
        connectionAttemptGeneration = UUID()
        cancelRemoteOperationTasks()
        clearActiveConnectionContext()
        macConnectionStatus = .unavailable
        replaceRemoteClient(with: nil)
        rawTerminalInputBuffer.clear()
    }

    /// Set `remoteClient` to a new value (possibly nil) and disconnect the
    /// previous one so we don't leak a persistent transport.
    private func replaceRemoteClient(with newValue: MobileCoreRPCClient?) {
        let previous = remoteClient
        remoteClient = newValue
        if let previous, previous !== newValue {
            Task { await previous.disconnect() }
        }
    }

    private func cancelRemoteOperationTasks() {
        hostIdentityAdoptionTask?.cancel()
        hostIdentityAdoptionTask = nil
        terminalSubscriptionRefreshTask?.cancel()
        terminalSubscriptionRefreshTask = nil
        createWorkspaceTask?.cancel()
        createWorkspaceTask = nil
        createWorkspaceTaskID = nil
        createTerminalTask?.cancel()
        createTerminalTask = nil
        createTerminalTaskID = nil
        workspaceListRefreshTask?.cancel()
        workspaceListRefreshTask = nil
        pullToRefreshTask?.cancel()
        pullToRefreshTask = nil
    }

    private func resetTerminalOutputTracking() {
        deliveredTerminalByteEndSeqBySurfaceID = [:]
        pendingTerminalByteEndSeqBySurfaceID = [:]
        terminalReplaySurfaceIDsInFlight = []
        terminalOutputQueuesBySurfaceID = [:]
        terminalOutputStreamTokensBySurfaceID = terminalOutputStreamTokensBySurfaceID.mapValues { _ in UUID() }
        terminalScrollQueueTokensBySurfaceID = [:]
        terminalScrollQueuesBySurfaceID = [:]
        terminalScrollbackPrefetchStatesBySurfaceID = [:]
        terminalOutputTransport = .rawBytes
        supportedHostCapabilities = []
        terminalSubscriptionRefreshTask?.cancel()
        terminalSubscriptionRefreshTask = nil
        stopRenderGridLivenessWatchdog(listenerID: nil)
        lastTerminalEventAt = nil
    }

    /// The one shared entry every pairing flow funnels through, so it is also the
    /// single `ios_pairing_started` fire-site. `method` is `qr`/`manual`/
    /// `attach_url`; pass `nil` for non-instrumented internal flows (preview).
    private func beginPairingAttempt(method: String? = nil) -> UUID {
        let attemptID = beginPairingValidationAttempt(method: method)
        connectionGeneration = UUID()
        connectionAttemptGeneration = UUID()
        cancelRemoteOperationTasks()
        rawTerminalInputBuffer.clear()
        clearPairingError()
        clearPairingVersionWarning()
        return attemptID
    }

    private func beginPairingValidationAttempt(method: String? = nil) -> UUID {
        let attemptID = UUID()
        pairingAttemptID = attemptID
        if let method {
            pairingAttemptStartedAt = runtime?.now() ?? Date()
            pairingAttemptMethod = method
            // Snapshot at attempt start: a successful connect mutates
            // `hasKnownPairedMac` before `succeeded` is recorded.
            pairingAttemptIsFirstPair = !hasKnownPairedMac
            analytics.capture("ios_pairing_started", [
                "method": .string(method),
                "is_first_pair": .bool(pairingAttemptIsFirstPair),
                "attempt_id": .string(attemptID.uuidString),
            ])
        } else {
            pairingAttemptStartedAt = nil
            pairingAttemptMethod = nil
        }
        return attemptID
    }

    /// Emits `ios_pairing_succeeded` once for the in-flight attempt, then clears
    /// the attempt timing so a later state change can't double-fire.
    private func recordPairingSucceeded() {
        guard let method = pairingAttemptMethod else { return }
        var props: [String: AnalyticsValue] = [
            "method": .string(method),
            "is_first_pair": .bool(pairingAttemptIsFirstPair),
            "attempt_id": .string(pairingAttemptID.uuidString),
        ]
        if let startedAt = pairingAttemptStartedAt {
            let ms = Int(((runtime?.now() ?? Date()).timeIntervalSince(startedAt)) * 1000)
            props["duration_ms"] = .int(max(0, ms))
        }
        if let route = activeRoute?.kind.rawValue {
            props["route"] = .string(route)
        }
        analytics.capture("ios_pairing_succeeded", props)
        pairingAttemptStartedAt = nil
        pairingAttemptMethod = nil
    }

    /// Emits `ios_pairing_failed` once for the in-flight attempt with a reason +
    /// phase, then clears the attempt timing so it can't double-fire.
    private func recordPairingFailed(reason: String, phase: String) {
        guard let method = pairingAttemptMethod else { return }
        var props: [String: AnalyticsValue] = [
            "method": .string(method),
            "reason": .string(reason),
            "failure_phase": .string(phase),
            "is_first_pair": .bool(pairingAttemptIsFirstPair),
            "attempt_id": .string(pairingAttemptID.uuidString),
        ]
        if let startedAt = pairingAttemptStartedAt {
            let ms = Int(((runtime?.now() ?? Date()).timeIntervalSince(startedAt)) * 1000)
            props["duration_ms"] = .int(max(0, ms))
        }
        analytics.capture("ios_pairing_failed", props)
        pairingAttemptStartedAt = nil
        pairingAttemptMethod = nil
    }

    private func isCurrentPairingAttempt(_ attemptID: UUID) -> Bool {
        pairingAttemptID == attemptID && isSignedIn
    }

    private func isCurrentConnectionAttempt(_ generation: UUID) -> Bool {
        generation == connectionAttemptGeneration && isSignedIn
    }

    /// Invalidate the in-flight attempt outside ``beginPairingAttempt(method:)``
    /// (cancel, sign-out, live-connection teardown), dropping its instrumentation
    /// so a stale attempt can never emit `ios_pairing_*` via a later auth eviction.
    private func invalidatePairingAttempt() {
        pairingAttemptID = UUID()
        pairingAttemptStartedAt = nil
        pairingAttemptMethod = nil
    }

    /// Apply a classified pairing failure to the user-visible error surface and
    /// emit its analytics reason in one place: the single failure sink for every
    /// non-cancelled, non-superseded failure, so a failed attempt always ends
    /// with a non-empty ``connectionError`` plus its ``connectionErrorGuidance``
    /// line and one `ios_pairing_failed` whose `reason` matches the message.
    /// ``connectionState``/``macConnectionStatus`` teardown stays at the call
    /// sites because some paths (auth re-auth) also flip ``connectionRequiresReauth``.
    private func applyPairingFailure(_ category: MobilePairingFailureCategory, phase: String) {
        // `.cancelled` (the only empty-message category) must be handled by
        // `catch is CancellationError` branches before classification.
        assert(!category.message.isEmpty, "applyPairingFailure must not receive .cancelled")
        if !category.message.isEmpty {
            connectionError = category.message
        }
        connectionErrorGuidance = category.guidance
        recordPairingFailed(reason: category.analyticsReason, phase: phase)
    }

    private func applyPairingValidationFailure(_ category: MobilePairingFailureCategory) {
        if pairingAttemptMethod == nil {
            _ = beginPairingValidationAttempt(method: "qr")
        }
        applyPairingFailure(category, phase: "validation")
    }

    /// Clear the error and its guidance together (never bare `connectionError
    /// = nil`) so guidance cannot linger under a cleared headline.
    private func clearPairingError() {
        connectionError = nil
        connectionErrorGuidance = nil
    }

    private func clearPairingVersionWarning() {
        pairingVersionWarning = nil
        pendingPairingVersionWarningURL = nil
    }

    static func emailFailure(
        for ticket: CmxAttachTicket,
        actualUserID: String?,
        actualEmail: String?
    ) -> MobilePairingFailureCategory? {
        if let expectedUserID = Self.mobileShellNormalizedNonEmpty(ticket.macUserID) {
            guard let actualUserID = Self.mobileShellNormalizedNonEmpty(actualUserID) else { return nil }
            guard actualUserID == expectedUserID else {
                return .authFailed
            }
            return nil
        }
        guard let actual = Self.mobileShellNormalizedEmail(actualEmail) else { return nil }
        if let expected = Self.mobileShellNormalizedEmail(ticket.macUserEmail) {
            guard actual == expected else {
                return .emailMismatch(expected: expected, actual: actual)
            }
            return nil
        }
        return nil
    }

    private func versionWarning(for ticket: CmxAttachTicket) -> String? {
        guard let macCompatibilityVersion = ticket.macPairingCompatibilityVersion,
              macCompatibilityVersion != CmxMobileDefaults.pairingCompatibilityVersion else {
            return nil
        }
        let phoneStamp = feedbackStampProvider()
        let phoneVersion = Self.mobileShellNormalizedNonEmpty(phoneStamp.appVersion)
        let macVersion = Self.mobileShellNormalizedNonEmpty(ticket.macAppVersion)
        let format = L10n.string(
            "mobile.pairing.versionWarningFormat",
            defaultValue: "This iPhone is running cmux %@, but the Mac is running cmux %@. Pairing across different compatibility levels can break terminal input, workspace sync, or notifications. Continue only if you trust this Mac and accept that some features may fail."
        )
        return String(
            format: format,
            Self.mobileShellVersionDisplay(
                version: phoneVersion,
                build: phoneStamp.appBuild,
                compatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion
            ),
            Self.mobileShellVersionDisplay(
                version: macVersion,
                build: ticket.macAppBuild,
                compatibilityVersion: macCompatibilityVersion
            )
        )
    }

    /// Record an `ios_pairing_failed` for a `connect()` that returned without
    /// connecting and already set a specific ``connectionError``: emits the reason
    /// `connect()` reported (fallback `other`) without overwriting the message.
    private func recordFailureForCurrentConnectionError(
        phase: String,
        category: MobilePairingFailureCategory? = nil
    ) {
        if connectionError == nil {
            // Defense in depth: never leave a silent revert if a future
            // `connect()` path returns without connecting or setting an error.
            applyPairingFailure(category ?? .unknown(host: nil, port: nil), phase: phase)
            return
        }
        recordPairingFailed(reason: category?.analyticsReason ?? "other", phase: phase)
    }

    /// Surface an operational error (a request failing on an already-live
    /// connection, e.g. create-workspace) through the same classifier as
    /// pairing. Does NOT emit `ios_pairing_failed` (no attempt is in flight).
    private func applyOperationalError(_ error: any Error) {
        let category = MobilePairingFailureCategory.classify(error: error, route: activeRoute)
        connectionError = category.message.isEmpty
            ? L10n.string("mobile.pairing.runtimeUnavailable", defaultValue: "Could not connect to your computer.")
            : category.message
        connectionErrorGuidance = category.guidance
    }

    /// How the preflight resolved: proceed, ``.offline`` applied, or superseded.
    private enum PairingPreflightOutcome {
        case proceed
        case failedOffline
        case superseded
    }

    /// Reachability preflight: with no satisfied network path, short-circuit the
    /// attempt with ``.offline`` instead of letting `NWConnection` stack per-route
    /// timeouts into an opaque ~60s wait. Loopback candidate routes skip it (they
    /// stay reachable offline; simulator/dev pairing to 127.0.0.1). Records a
    /// ``DiagnosticEventCode/pairUnreachable`` diagnostic (no host/secret).
    private func failPairingIfOffline(
        attemptID: UUID,
        phase: String,
        routes: [CmxAttachRoute]
    ) async -> PairingPreflightOutcome {
        if routes.contains(where: MobileShellRouteAuthPolicy.routeIsLoopback) { return .proceed }
        guard await reachability.isOnline == false else { return .proceed }
        guard isCurrentPairingAttempt(attemptID) else { return .superseded }
        mobileShellLog.info("pairing preflight: device offline, short-circuiting")
        diagnosticLog?.record(DiagnosticEvent(.pairUnreachable))
        applyPairingFailure(.offline, phase: phase)
        connectionState = .disconnected
        macConnectionStatus = .unavailable
        clearRemoteConnectionContext()
        return .failedOffline
    }

    private func clearCreateWorkspaceTask(id: UUID) {
        guard createWorkspaceTaskID == id else { return }
        createWorkspaceTask = nil
        createWorkspaceTaskID = nil
    }

    private func clearCreateTerminalTask(id: UUID) {
        guard createTerminalTaskID == id else { return }
        createTerminalTask = nil
        createTerminalTaskID = nil
    }

    private func isCurrentRemoteOperation(client: MobileCoreRPCClient, generation: UUID) -> Bool {
        isCurrentRemoteConnection(client: client, generation: generation)
            && connectionState == .connected
    }

    private func isCurrentRemoteConnection(client: MobileCoreRPCClient, generation: UUID) -> Bool {
        generation == connectionGeneration
            && client === remoteClient
            && isSignedIn
    }

    private func markMacConnectionHealthy() {
        guard connectionState == .connected else {
            macConnectionStatus = .unavailable
            return
        }
        macConnectionStatus = .connected
        isRecoveringConnection = false
        connectionRecoveryFailed = false
        connectionRequiresReauth = false
    }

    private func markMacConnectionReconnecting() {
        guard connectionState == .connected, remoteClient != nil else {
            macConnectionStatus = .unavailable
            return
        }
        macConnectionStatus = .reconnecting
        isRecoveringConnection = true
        connectionRecoveryFailed = false
    }

    private func markMacConnectionUnavailable() {
        guard connectionState == .connected else {
            macConnectionStatus = .unavailable
            return
        }
        macConnectionStatus = .unavailable
        isRecoveringConnection = false
        connectionRecoveryFailed = true
    }

    func markMacConnectionUnavailableIfNeeded(after error: any Error) {
        guard MobileShellMacAvailabilityFailureClassifier().isAvailabilityFailure(error) else { return }
        markMacConnectionUnavailable()
    }

    private func syncSelectedTerminalForWorkspace() {
        guard let selectedWorkspace else {
            selectedTerminalID = nil
            return
        }
        if let selectedTerminalID,
           let selectedTerminal = selectedWorkspace.terminals.first(where: { $0.id == selectedTerminalID }),
           selectedTerminal.isReady || !selectedWorkspace.hasReadyTerminal {
            return
        }
        selectedTerminalID = selectedWorkspace.preferredTerminal?.id
    }

    // MARK: - Per-terminal composer drafts

    /// Enqueue one draft-store operation on a strictly ordered (FIFO) pipeline.
    ///
    /// All draft persistence is fire-and-forget from the caller's point of view,
    /// but independent unstructured `Task`s are NOT ordered relative to each
    /// other: an older keystroke save could reach the store actor after a newer
    /// save, a post-send clear, or the sign-out wipe, resurrecting stale (or
    /// another account's) text. Chaining every operation onto the previous one
    /// makes store effects apply in exactly the order they were issued from the
    /// main actor, which restores the two invariants the store exists for: sent
    /// or superseded drafts never win over newer state, and nothing written
    /// before sign-out survives the sign-out wipe.
    ///
    /// Operations are tiny (one actor dictionary access) and keystroke saves
    /// coalesce before they reach the pipeline (see ``persistCurrentDraft()``),
    /// so the chain stays short and bounded under typing bursts; only the tail
    /// task is retained.
    @discardableResult
    private func enqueueDraftOperation(
        _ operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let previous = draftOperationTail
        let task = Task {
            await previous?.value
            await operation()
        }
        draftOperationTail = task
        return task
    }

    /// Wait until every draft operation enqueued so far has been applied to the
    /// store. Test seam: lets tests assert on store contents without sleeping.
    func drainDraftOperationsForTesting() async {
        await draftOperationTail?.value
    }

    /// Save the live ``terminalInputText`` under the currently selected
    /// terminal. Called from the field's `didSet`. A no-op when there is no
    /// selected terminal (nothing to key the draft to) or no draft store wired.
    ///
    /// Saves COALESCE per terminal: the edit overwrites the terminal's entry in
    /// ``pendingDraftSaveTextByTerminalID`` and queues a flush only when none is
    /// already queued for that terminal. The flush reads the LATEST entry when
    /// it executes, so a typing burst behind a slow store applies as one save of
    /// the final text instead of queuing every intermediate snapshot (whose
    /// retained memory would otherwise grow as edits × draft size). Barrier
    /// operations (the switch save/load, the post-send clear, the sign-out wipe)
    /// still order strictly after any queued flush via the shared FIFO.
    private func persistCurrentDraft() {
        guard let draftStore, let terminalID = selectedTerminalID?.rawValue else { return }
        let flushAlreadyQueued = pendingDraftSaveTextByTerminalID[terminalID] != nil
        pendingDraftSaveTextByTerminalID[terminalID] = terminalInputText
        guard !flushAlreadyQueued else { return }
        enqueueDraftOperation { [weak self] in
            guard let text = await self?.takePendingDraftSave(forTerminalID: terminalID) else { return }
            await draftStore.saveDraft(text, forTerminalID: terminalID)
        }
    }

    /// Dequeue the latest unflushed keystroke draft for `terminalID`, clearing
    /// its entry so the next edit arms a fresh flush. Called by the queued flush
    /// at execution time, so it always saves the newest text.
    private func takePendingDraftSave(forTerminalID terminalID: String) -> String? {
        defer { pendingDraftSaveTextByTerminalID[terminalID] = nil }
        return pendingDraftSaveTextByTerminalID[terminalID]
    }

    /// Swap the composer draft when the selected terminal changes: save the
    /// outgoing terminal's text under its own key, then load the incoming
    /// terminal's saved draft into ``terminalInputText``.
    ///
    /// The load is guarded by ``isLoadingDraft`` so the field's `didSet` does not
    /// re-save the just-loaded value (and so the load can't race the key swap).
    /// While the incoming draft is fetched asynchronously the field is cleared, so
    /// the previous terminal's text never bleeds into a terminal that has no draft.
    /// - Parameters:
    ///   - outgoingID: The terminal being switched away from, or `nil`.
    ///   - outgoingText: That terminal's draft text at the moment of the switch.
    ///   - incomingID: The terminal being switched to, or `nil`.
    private func swapDraft(
        from outgoingID: MobileTerminalPreview.ID?,
        outgoingText: String,
        to incomingID: MobileTerminalPreview.ID?
    ) {
        guard let draftStore else { return }
        // The field represents the outgoing terminal's draft only when no load
        // is still pending for it. During a fast A -> B -> C switch, B's load
        // has not applied yet and the field is the transient cleared
        // placeholder, not B's draft; persisting it would erase B's real stored
        // draft. (A user edit clears the pending marker, so an edited field is
        // always authoritative and still saved.)
        let outgoingFieldIsAuthoritative = outgoingID != nil && draftLoadPendingTerminalID != outgoingID
        draftLoadPendingTerminalID = incomingID
        // Clear the field synchronously so the old terminal's text is not briefly
        // shown under the new terminal while its draft loads. Guarded so this
        // clear is not itself saved.
        if !terminalInputText.isEmpty {
            isLoadingDraft = true
            terminalInputText = ""
            isLoadingDraft = false
        }
        enqueueDraftOperation { [weak self] in
            if let outgoingID, outgoingFieldIsAuthoritative {
                await draftStore.saveDraft(outgoingText, forTerminalID: outgoingID.rawValue)
            }
            guard let incomingID else { return }
            let restored = await draftStore.draft(forTerminalID: incomingID.rawValue) ?? ""
            await self?.applyLoadedDraft(restored, forTerminalID: incomingID)
        }
    }

    /// Apply a draft fetched off the main actor back into ``terminalInputText``.
    ///
    /// Applied only if this load is still the pending one — a fast re-switch
    /// repoints ``draftLoadPendingTerminalID`` at the newer incoming terminal,
    /// and a user edit clears it entirely (live input wins, even when the user
    /// deleted everything: a late load must not resurrect deleted text into the
    /// deliberately emptied field). The selected-terminal and empty-field
    /// guards stay as defense in depth for the same races. The restore write is
    /// guarded so it is not re-saved. An empty restored draft is a no-op.
    private func applyLoadedDraft(_ draft: String, forTerminalID terminalID: MobileTerminalPreview.ID) {
        guard draftLoadPendingTerminalID == terminalID else { return }
        draftLoadPendingTerminalID = nil
        guard selectedTerminalID == terminalID,
              terminalInputText.isEmpty,
              !draft.isEmpty else { return }
        isLoadingDraft = true
        terminalInputText = draft
        isLoadingDraft = false
    }

    private func viewportKey(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) -> MobileTerminalViewportKey {
        MobileTerminalViewportKey(workspaceID: workspaceID, terminalID: terminalID)
    }

    private func createRemoteWorkspace() async {
        guard let client = remoteClient else { return }
        let generation = connectionGeneration
        do {
            let resultData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(method: "workspace.create")
            )
            let response = try MobileSyncWorkspaceListResponse.decode(resultData)
            guard isCurrentRemoteOperation(client: client, generation: generation),
                  !Task.isCancelled else { return }
            applyRemoteWorkspaceList(response, mergeExistingWorkspaces: true)
            let createdWorkspace = response.createdWorkspaceID.map(MobileWorkspacePreview.ID.init(rawValue:))
            if let createdWorkspace {
                setSelectedWorkspaceID(createdWorkspace)
            }
            syncSelectedTerminalForWorkspace()
            if createdWorkspace != nil {
                // A "+" actually created and selected a new workspace, so its
                // terminal is freshly created: don't pop the keyboard on mount.
                // When no workspace was created the selection never moved, so we
                // must not suppress the user's current terminal.
                suppressTerminalAutoFocusOnNextAttach(for: selectedTerminalID)
            }
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return }
            markMacConnectionUnavailableIfNeeded(after: error)
            applyOperationalError(error)
        }
    }

    private func createRemoteTerminal(in explicitWorkspaceID: MobileWorkspacePreview.ID? = nil) async {
        guard let client = remoteClient,
              let workspaceID = (explicitWorkspaceID ?? selectedWorkspace?.id)?.rawValue else { return }
        let requestedWorkspaceID = MobileWorkspacePreview.ID(rawValue: workspaceID)
        let generation = connectionGeneration
        do {
            let resultData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "terminal.create",
                    params: ["workspace_id": workspaceID]
                )
            )
            let response = try MobileSyncWorkspaceListResponse.decode(resultData)
            guard isCurrentRemoteOperation(client: client, generation: generation),
                  !Task.isCancelled else { return }
            applyRemoteWorkspaceList(response, mergeExistingWorkspaces: true)
            if selectedWorkspaceID == requestedWorkspaceID,
               let createdID = response.createdTerminalID {
                let createdTerminalID = MobileTerminalPreview.ID(rawValue: createdID)
                selectedTerminalID = createdTerminalID
                suppressTerminalAutoFocusOnNextAttach(for: createdTerminalID)
            }
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return }
            markMacConnectionUnavailableIfNeeded(after: error)
            applyOperationalError(error)
        }
    }

    private func sendRemoteTerminalInput(_ text: String) async {
        guard let workspaceID = selectedWorkspace?.id,
              let terminalID = selectedTerminalID else {
            #if DEBUG
            mobileShellLog.info("skip remote terminal input selectedWorkspace=\(self.selectedWorkspace == nil ? 0 : 1, privacy: .public) selectedTerminal=\(self.selectedTerminalID == nil ? 0 : 1, privacy: .public)")
            #endif
            return
        }
        await sendRemoteTerminalInput(text, workspaceID: workspaceID, terminalID: terminalID)
    }

    private func sendRemoteTerminalInput(
        _ text: String,
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) async {
        guard let client = remoteClient else {
            #if DEBUG
            mobileShellLog.info("skip remote terminal input remoteClient=0")
            #endif
            return
        }
        let generation = connectionGeneration
        do {
            #if DEBUG
            mobileShellLog.debug("send remote terminal input byteCount=\(text.utf8.count, privacy: .public) workspace=\(workspaceID.rawValue, privacy: .private) terminal=\(terminalID.rawValue, privacy: .private)")
            #endif
            let key = viewportKey(workspaceID: workspaceID, terminalID: terminalID)
            var params: [String: Any] = [
                "workspace_id": workspaceID.rawValue,
                "surface_id": terminalID.rawValue,
                "text": text,
                "client_id": clientID,
            ]
            if let viewportSize = reportedViewportSizesByTerminalKey[key] {
                params["viewport_columns"] = viewportSize.columns
                params["viewport_rows"] = viewportSize.rows
            }
            let responseData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "terminal.input",
                    params: params
                )
            )
            guard isCurrentRemoteOperation(client: client, generation: generation) else { return }
            handleTerminalInputResponse(responseData, surfaceID: terminalID.rawValue)
        } catch {
            guard generation == connectionGeneration else { return }
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return }
            markMacConnectionUnavailableIfNeeded(after: error)
            applyOperationalError(error)
        }
    }

    /// - Returns: `true` when the Mac acknowledged the paste, `false` when there
    ///   is no selected workspace/terminal or the send failed.
    @discardableResult
    private func sendRemoteTerminalPaste(_ text: String, submitKey: String) async -> Bool {
        guard let workspaceID = selectedWorkspace?.id,
              let terminalID = selectedTerminalID else {
            #if DEBUG
            mobileShellLog.info("skip remote terminal paste selectedWorkspace=\(self.selectedWorkspace == nil ? 0 : 1, privacy: .public) selectedTerminal=\(self.selectedTerminalID == nil ? 0 : 1, privacy: .public)")
            #endif
            return false
        }
        return await sendRemoteTerminalPaste(text, submitKey: submitKey, workspaceID: workspaceID, terminalID: terminalID)
    }

    /// Deliver a composed block to the Mac surface via `terminal.paste`: a
    /// bracketed paste (so multi-line text is inserted as one literal block)
    /// followed by an optional submit key. Mirrors ``sendRemoteTerminalInput(_:workspaceID:terminalID:)``
    /// but takes the dedicated paste path instead of the raw `terminal.input`
    /// path, which rewrites newlines to carriage returns.
    ///
    /// - Returns: `true` when the Mac acknowledged the paste, `false` on any
    ///   failure (no client, a stale generation, or an RPC error such as
    ///   `method_not_found` from an older host). Callers use this to keep the
    ///   composer text on failure instead of clearing it optimistically.
    @discardableResult
    private func sendRemoteTerminalPaste(
        _ text: String,
        submitKey: String,
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) async -> Bool {
        guard let client = remoteClient else {
            #if DEBUG
            mobileShellLog.info("skip remote terminal paste remoteClient=0")
            #endif
            return false
        }
        let generation = connectionGeneration
        do {
            #if DEBUG
            mobileShellLog.debug("send remote terminal paste byteCount=\(text.utf8.count, privacy: .public) submit=\(submitKey, privacy: .public) workspace=\(workspaceID.rawValue, privacy: .private) terminal=\(terminalID.rawValue, privacy: .private)")
            #endif
            let key = viewportKey(workspaceID: workspaceID, terminalID: terminalID)
            var params: [String: Any] = [
                "workspace_id": workspaceID.rawValue,
                "surface_id": terminalID.rawValue,
                "text": text,
                "submit_key": submitKey,
                "client_id": clientID,
            ]
            if let viewportSize = reportedViewportSizesByTerminalKey[key] {
                params["viewport_columns"] = viewportSize.columns
                params["viewport_rows"] = viewportSize.rows
            }
            let responseData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "terminal.paste",
                    params: params
                )
            )
            // The Mac acked the paste: the text is applied regardless of whether a
            // reconnect superseded this client while the request was in flight.
            // Only the per-connection response bookkeeping is generation-guarded;
            // returning failure here would keep the composer draft and a retry
            // would paste the same block twice.
            if isCurrentRemoteOperation(client: client, generation: generation) {
                handleTerminalInputResponse(responseData, surfaceID: terminalID.rawValue)
            }
            return true
        } catch {
            guard generation == connectionGeneration else { return false }
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return false }
            markMacConnectionUnavailableIfNeeded(after: error)
            applyOperationalError(error)
            return false
        }
    }

    /// Forward an image the user pasted on the phone to the currently selected
    /// remote terminal. The bytes travel as base64 in `terminal.paste_image`; the
    /// Mac writes them to a temp file and injects the path into the terminal so
    /// the running TUI (e.g. Claude Code) attaches the image the same way a local
    /// clipboard-image paste does.
    ///
    /// - Parameters:
    ///   - data: The encoded image bytes (PNG/JPEG/…).
    ///   - format: A lowercase file-extension hint (e.g. `"png"`). The Mac
    ///     sanitizes it and defaults to `png` for anything unrecognized.
    public func submitTerminalPasteImage(_ data: Data, format: String) async {
        guard !data.isEmpty else { return }
        guard let workspaceID = selectedWorkspace?.id,
              let terminalID = selectedTerminalID else {
            return
        }
        guard remoteClient != nil else { return }
        await sendRemoteTerminalPasteImage(
            data,
            format: format,
            workspaceID: workspaceID,
            terminalID: terminalID
        )
    }

    private func sendRemoteTerminalPasteImage(
        _ data: Data,
        format: String,
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) async {
        guard let client = remoteClient else { return }
        let generation = connectionGeneration
        do {
            #if DEBUG
            mobileShellLog.debug("send remote terminal paste image byteCount=\(data.count, privacy: .public) format=\(format, privacy: .public)")
            #endif
            let params: [String: Any] = [
                "workspace_id": workspaceID.rawValue,
                "surface_id": terminalID.rawValue,
                "image_base64": data.base64EncodedString(),
                "image_format": format,
                "client_id": clientID,
            ]
            let responseData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "terminal.paste_image",
                    params: params
                )
            )
            guard isCurrentRemoteOperation(client: client, generation: generation) else { return }
            handleTerminalInputResponse(responseData, surfaceID: terminalID.rawValue)
        } catch {
            guard generation == connectionGeneration else { return }
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return }
            markMacConnectionUnavailableIfNeeded(after: error)
            applyOperationalError(error)
        }
    }

    private var terminalEventStreamID: String {
        "ios-terminal-events-\(clientID)"
    }

    /// Outcome of a `mobile.events.subscribe` round-trip.
    private enum TerminalEventSubscriptionAck {
        case failed
        /// The host registered (or re-asserted) the subscription.
        /// `alreadySubscribed == false` means this acknowledgement INSTALLED
        /// the registration, so events emitted while it was absent were never
        /// delivered; `nil` means the host predates the field (treat as
        /// already active).
        case subscribed(alreadySubscribed: Bool?)

        var isSubscribed: Bool {
            if case .subscribed = self { return true }
            return false
        }
    }

    private func requestTerminalEventSubscription(
        client: MobileCoreRPCClient,
        reason: String,
        topics: [String]
    ) async -> TerminalEventSubscriptionAck {
        let requestData: Data
        do {
            requestData = try MobileCoreRPCClient.requestData(
                method: "mobile.events.subscribe",
                params: [
                    "stream_id": terminalEventStreamID,
                    "topics": topics,
                ]
            )
        } catch {
            mobileShellLog.error("subscribe payload encode failed: \(String(describing: error), privacy: .private)")
            return .failed
        }
        let responseData: Data
        do {
            responseData = try await client.sendRequest(requestData)
        } catch {
            if Task.isCancelled {
                // A superseding generation (resync, disconnect) cancelled this
                // request; the session layer surfaces that cancellation as
                // `requestTimedOut`. Not a host failure: stay quiet so the log
                // does not report a self-inflicted cancel as a wire timeout.
                mobileShellLog.info("subscribe cancelled reason=\(reason, privacy: .public)")
                return .failed
            }
            mobileShellLog.error("subscribe failed reason=\(reason, privacy: .public): \(String(describing: error), privacy: .private)")
            // Event-stream (re)subscribe is the view-only/foreground-resume path.
            // A definitive auth failure here (RPC layer already tried a
            // force-refresh + retry) must drive the re-auth prompt instead of a
            // silently stale live frame.
            if remoteClient === client {
                _ = disconnectForAuthorizationFailureIfNeeded(error)
            }
            return .failed
        }
        let response = try? MobileEventSubscribeResponse.decode(responseData)
        guard let streamID = response?.streamID, !streamID.isEmpty else {
            mobileShellLog.error("subscribe response missing stream_id reason=\(reason, privacy: .public)")
            return .failed
        }
        #if DEBUG
        mobileShellLog.info("subscribe active reason=\(reason, privacy: .public) streamID=\(streamID, privacy: .public)")
        #endif
        return .subscribed(alreadySubscribed: response?.alreadySubscribed)
    }

    private func resolveTerminalOutputTransport(client: MobileCoreRPCClient) async -> TerminalOutputTransport {
        let fallback: TerminalOutputTransport = .rawBytes
        do {
            let data = try await client.sendRequest(
                MobileCoreRPCClient.requestData(method: "mobile.host.status", params: [:]),
                timeoutNanoseconds: Self.terminalOutputCapabilityTimeoutNanoseconds
            )
            // The status round-trip suspends, and a reconnect/new pairing can
            // install a different `remoteClient` (and a fresh `activeTicket`)
            // in the meantime. A stale response must not mutate the current
            // connection's transport state, and above all must not adopt the
            // OLD Mac's identity onto the NEW connection's empty-id ticket
            // (which would persist the wrong paired-Mac record). The stale
            // listener task tears itself down via its own `remoteClient`
            // guards; returning the fallback here is inert.
            guard remoteClient === client else { return fallback }
            guard let payload = try? MobileHostStatusResponse.decode(data) else {
                terminalOutputTransport = fallback
                // Preserve learned capabilities during transient status decode failures.
                scheduleHostIdentityAdoptionIfNeeded(client: client)
                return fallback
            }
            supportedHostCapabilities = Set(payload.capabilities)
            await applyHostReportedIdentity(
                client: client,
                deviceID: payload.macDeviceID,
                displayName: payload.macDisplayName
            )
            // A decoded status can still be identity-free: the probe's token
            // attach is best-effort, and the host withholds identity from an
            // unverified caller. If the v2 QR ticket is still anonymous after
            // applying, run the dedicated recovery (it re-asks the token
            // provider and no-ops once an identity is adopted).
            scheduleHostIdentityAdoptionIfNeeded(client: client)
            let transport: TerminalOutputTransport = payload.capabilities.contains(Self.terminalRenderGridCapability) ||
                payload.terminalFidelity == "render_grid" ? .renderGrid : .rawBytes
            terminalOutputTransport = transport
            MobileDebugLog.anchormux("sync.transport=\(transport == .renderGrid ? "render_grid" : "raw_bytes")")
            return transport
        } catch {
            guard remoteClient === client else { return fallback }
            terminalOutputTransport = fallback
            // Preserve learned capabilities during transient reconnect probe failures.
            // The probe is best-effort for the terminal transport, but a
            // freshly QR-paired Mac still needs its identity recovered, with
            // a real timeout instead of the probe's 750ms.
            scheduleHostIdentityAdoptionIfNeeded(client: client)
            MobileDebugLog.anchormux("sync.transport=raw_bytes reason=status_failed")
            return fallback
        }
    }

    private func refreshTerminalEventSubscription(reason: String) {
        guard let client = remoteClient, connectionState == .connected else { return }
        guard runtime?.supportsServerPushEvents ?? true else { return }
        guard terminalSubscriptionRefreshTask == nil else { return }
        terminalSubscriptionRefreshTask = Task { @MainActor [weak self] in
            defer { self?.terminalSubscriptionRefreshTask = nil }
            guard let self else { return }
            let topics = self.terminalOutputTransport.eventTopics
            _ = await self.requestTerminalEventSubscription(
                client: client,
                reason: reason,
                topics: topics
            )
        }
    }

    private func startTerminalRefreshPolling() {
        guard let client = remoteClient else { return }
        guard runtime?.supportsServerPushEvents ?? true else { return }
        guard terminalEventListenerTask == nil else { return }
        let listenerID = UUID()
        terminalEventListenerID = listenerID
        // Arm the liveness watchdog for this subscription generation. Done only
        // inside the push-events path (after the guard above) so scripted
        // transport tests, which set `supportsServerPushEvents = false`, never
        // schedule speculative re-subscribes. A fresh subscription gets a full
        // silence window before it can be judged dead.
        startRenderGridLivenessWatchdog(listenerID: listenerID)
        terminalEventListenerTask = Task { @MainActor [weak self] in
            defer {
                if self?.terminalEventListenerID == listenerID {
                    self?.terminalEventListenerTask = nil
                    self?.terminalEventListenerID = nil
                    // Only this generation's watchdog is torn down here. The
                    // `== listenerID` guard matters because `restartEventStream`
                    // does stop()+start() and the old listener's defer can run
                    // asynchronously after the new listener+watchdog are armed;
                    // without the guard a stale teardown would cancel the fresh
                    // watchdog.
                    self?.stopRenderGridLivenessWatchdog(listenerID: listenerID)
                }
            }

            let outputTransport = await self?.resolveTerminalOutputTransport(client: client) ?? .rawBytes
            let topics = outputTransport.eventTopics
            let stream = await client.subscribe(to: Set(topics))
            // Kick off the server-side enable handshake CONCURRENTLY with
            // consumption. The old structure awaited the ack here, which
            // parked the consumer loop while events from a still-active prior
            // server subscription piled up unconsumed in `stream`'s buffer;
            // the liveness watchdog (stamped only at consumption) then read a
            // healthy establishing stream as silence and false-fired, and its
            // resync cancelled this very ack (surfacing a bogus
            // `requestTimedOut`). Consuming from the start keeps the liveness
            // clock coupled to actual event arrival.
            self?.beginTerminalEventSubscriptionStart(
                client: client,
                listenerID: listenerID,
                topics: topics,
                transport: outputTransport
            )
            // Keep the listener alive without keeping the shell store alive.
            for await event in stream {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard self.remoteClient === client, self.connectionState == .connected else { return }
                // Any yielded envelope proves the transport is still pushing, so
                // it resets the liveness window (not just render_grid events).
                self.recordTerminalEventStreamLiveness()
                self.markMacConnectionHealthy()
                if event.topic == "workspace.updated" {
                    self.scheduleWorkspaceListRefreshFromEvent()
                } else if event.topic == "terminal.render_grid" {
                    self.handleTerminalRenderGridEvent(event)
                } else if event.topic == "terminal.bytes" {
                    // Raw PTY bytes coming from the Mac surface's libghostty
                    // pty-tee. This is the compatibility fallback when the Mac
                    // host does not advertise `terminal.render_grid.v1`.
                    self.handleTerminalBytesEvent(event)
                } else if event.topic == "notification.dismissed" {
                    await self.handleNotificationDismissedEvent(event)
                } else if event.topic == "notification.badge" {
                    self.handleNotificationBadgeEvent(event)
                }
            }
            guard let self else { return }
            self.handleTerminalEventStreamEnded(listenerID: listenerID, client: client)
        }
    }

    /// Run the `mobile.events.subscribe` (reason `start`) handshake for one
    /// listener generation, concurrently with that generation's consumer loop.
    ///
    /// Success and failure are only acted on while the generation is still
    /// current: a superseded or cancelled handshake exits silently so a stale
    /// generation can never mark the connection unavailable underneath a
    /// fresh, healthy one (the bisected false-fire loop did exactly that via
    /// its self-cancelled ack).
    private func beginTerminalEventSubscriptionStart(
        client: MobileCoreRPCClient,
        listenerID: UUID,
        topics: [String],
        transport: TerminalOutputTransport
    ) {
        guard terminalEventListenerID == listenerID else { return }
        terminalSubscriptionStartTask?.cancel()
        terminalSubscriptionStartTask = Task { @MainActor [weak self] in
            let ack = await self?.requestTerminalEventSubscription(
                client: client,
                reason: "start",
                topics: topics
            ) ?? .failed
            guard let self else { return }
            guard !Task.isCancelled, self.terminalEventListenerID == listenerID else { return }
            self.terminalSubscriptionStartTask = nil
            guard ack.isSubscribed else {
                MobileDebugLog.anchormux("sync.subscribe_failed reason=start")
                self.diagnosticLog?.record(DiagnosticEvent(.error))
                self.stopTerminalRefreshPolling()
                self.markMacConnectionUnavailable()
                return
            }
            self.markMacConnectionHealthy()
            MobileDebugLog.anchormux("sync.subscribe_ok topics=\(topics.count) transport=\(transport)")
            self.scheduleNotificationReconcile(client: client)
        }
    }

    private func handleTerminalEventStreamEnded(listenerID: UUID, client: MobileCoreRPCClient) {
        guard !Task.isCancelled,
              terminalEventListenerID == listenerID,
              remoteClient === client,
              connectionState == .connected else {
            return
        }
        if terminalSubscriptionStartTask != nil {
            // The stream ended while this generation's enable handshake was
            // still in flight: the transport dropped before the subscription
            // ever delivered. Restarting here would supersede the generation
            // and silently swallow the handshake's failure verdict (its ack
            // guard sees a newer listenerID), so a closed transport would
            // loop `reconnecting` forever. Converge instead: a stream that
            // dies before its handshake completes IS a failed start.
            mobileShellLog.info("terminal event stream ended before subscribe ack, marking unavailable")
            MobileDebugLog.anchormux("sync.stream_ended before subscribe ack; failed start")
            diagnosticLog?.record(DiagnosticEvent(.error))
            stopTerminalRefreshPolling()
            markMacConnectionUnavailable()
            return
        }
        mobileShellLog.info("terminal event stream ended, restarting")
        MobileDebugLog.anchormux("sync.stream_ended restarting (render-grid push stopped; falling back to poll)")
        diagnosticLog?.record(DiagnosticEvent(.streamEnded))
        markMacConnectionReconnecting()
        terminalEventListenerTask = nil
        terminalEventListenerID = nil
        startTerminalRefreshPolling()
        scheduleWorkspaceListRefreshFromEvent()
    }

    // MARK: - Render-grid liveness watchdog

    /// Start a repeating `DispatchSourceTimer` that watches for prolonged silence
    /// on the render-grid push subscription identified by `listenerID`.
    ///
    /// The listener's `for await` loop blocks indefinitely when the underlying
    /// connection half-dies, so we cannot detect death from inside it. This timer
    /// ticks independently and, on each tick, hops to the main actor to compare
    /// `lastTerminalEventAt` against `renderGridLivenessSilenceThreshold`. While
    /// events keep arriving, `lastTerminalEventAt` stays fresh and every tick is a
    /// no-op. A threshold crossing is treated as a SUSPICION, not a verdict: an
    /// idle terminal pushes no events, so the tick first re-asserts the
    /// subscription with a bounded idempotent `mobile.events.subscribe`
    /// round-trip and only recovers when that probe fails (see
    /// ``checkRenderGridLiveness(listenerID:)``).
    private func startRenderGridLivenessWatchdog(listenerID: UUID) {
        stopRenderGridLivenessWatchdog(listenerID: nil)
        renderGridLivenessListenerID = listenerID
        // Reset the window so a freshly-armed subscription gets the full silence
        // budget before it can be judged dead.
        recordTerminalEventStreamLiveness()
        // DispatchSourceTimer is the allowed low-level primitive for periodic
        // event delivery. It fires on the MAIN queue on purpose: the handler is
        // inferred @MainActor (it touches main-actor store state), and a timer on
        // a background queue made that @MainActor handler run off the main
        // executor, which Swift 6 traps as EXC_BREAKPOINT
        // (swift_task_isCurrentExecutor -> dispatch_assert_queue_fail). Running
        // on .main keeps isolation and executor in agreement; the work is just a
        // timestamp comparison every few seconds, so main-queue cost is trivial.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = Self.renderGridLivenessCheckInterval
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(500)
        )
        timer.setEventHandler { [weak self] in
            // Genuinely on the main queue (timer queue is .main), so assumeIsolated
            // is sound and avoids an async Task hop.
            MainActor.assumeIsolated {
                self?.checkRenderGridLiveness(listenerID: listenerID)
            }
        }
        renderGridLivenessTimer = timer
        timer.resume()
    }

    /// Cancel the liveness watchdog. When `listenerID` is non-nil the cancel only
    /// applies if it matches the armed generation, so a stale listener's async
    /// `defer` cannot tear down a watchdog that a newer subscription just armed.
    private func stopRenderGridLivenessWatchdog(listenerID: UUID?) {
        if let listenerID, renderGridLivenessListenerID != listenerID {
            return
        }
        renderGridLivenessTimer?.cancel()
        renderGridLivenessTimer = nil
        renderGridLivenessListenerID = nil
        renderGridLivenessProbeTask?.cancel()
        renderGridLivenessProbeTask = nil
        renderGridLivenessProbeID = nil
    }

    /// Single ownership point for the liveness clock the watchdog reads.
    ///
    /// Stamped by (1) every envelope the listener loop actually consumes,
    /// (2) a successful host probe (positive proof the channel is alive while
    /// the terminal is merely idle), and (3) the arming of a new watchdog
    /// generation, as the clean generation reset. The watchdog compares this
    /// single record against `renderGridLivenessSilenceThreshold`. The only
    /// other write is `resetTerminalOutputTracking` clearing it to nil when
    /// the connection context is torn down entirely.
    private func recordTerminalEventStreamLiveness() {
        lastTerminalEventAt = runtime?.now() ?? Date()
    }

    #if DEBUG
    /// Test-only: run one liveness evaluation for the currently armed watchdog
    /// generation, exactly as a `DispatchSourceTimer` tick would. Lets package
    /// tests drive the silence check deterministically against an injected
    /// clock instead of waiting on the wall-clock tick cadence.
    func debugRunRenderGridLivenessCheckForTesting() {
        guard let listenerID = renderGridLivenessListenerID else { return }
        checkRenderGridLiveness(listenerID: listenerID)
    }
    #endif

    /// One watchdog tick on the main actor: if the subscription generation still
    /// matches, the store is connected, and the stream has been silent past the
    /// threshold, verify the silence with a bounded host probe and only tear
    /// down + re-subscribe + replay (via the existing resync path) when the
    /// probe fails.
    ///
    /// The probe step exists because silence is ambiguous: a healthy idle
    /// terminal emits nothing (the Mac dedupes unchanged render-grid frames by
    /// row signature and stateSeq), which is indistinguishable by wall clock
    /// from the half-dead transport this watchdog was built to catch. Treating
    /// silence alone as death made the watchdog tear down and full-grid-replay
    /// every healthy idle subscription every ~10.5s, forever (the 2026-06-10
    /// Release-sim bisect finding).
    ///
    /// The probe is an idempotent `mobile.events.subscribe` for the SAME
    /// stream id and current topics, not a generic ping: a completed
    /// round-trip proves the transport the events ride on is alive AND that
    /// the server-side registration is (re)installed, and the host's
    /// subscription tracker re-evaluates producer demand on every replace. A
    /// generic `mobile.host.status` answer could mask a dropped registration
    /// behind a live RPC channel forever. Unlike the resync recovery, the
    /// probe restarts nothing: no listener teardown, no replay, no stream
    /// interruption.
    private func checkRenderGridLiveness(listenerID: UUID) {
        guard renderGridLivenessListenerID == listenerID else { return }
        guard let client = remoteClient, connectionState == .connected else { return }
        guard terminalEventListenerID == listenerID else { return }
        let now = runtime?.now() ?? Date()
        let last = lastTerminalEventAt ?? now
        let silent = now.timeIntervalSince(last)
        guard silent >= Self.renderGridLivenessSilenceThreshold else { return }
        guard renderGridLivenessProbeTask == nil else { return }
        let probeTimeoutNanoseconds = runtime?.livenessProbeTimeoutNanoseconds
            ?? 3_000_000_000
        let topics = terminalOutputTransport.eventTopics
        let probeID = UUID()
        renderGridLivenessProbeID = probeID
        renderGridLivenessProbeTask = Task { @MainActor [weak self] in
            let ack = await self?.probeEventSubscriptionLiveness(
                client: client,
                topics: topics,
                timeoutNanoseconds: probeTimeoutNanoseconds
            ) ?? .failed
            guard let self else { return }
            // Only the probe that owns the single-flight slot may clear it; a
            // superseded probe completing late returns without touching the
            // newer generation's in-flight slot.
            guard self.renderGridLivenessProbeID == probeID else { return }
            self.renderGridLivenessProbeTask = nil
            self.renderGridLivenessProbeID = nil
            guard !Task.isCancelled,
                  self.renderGridLivenessListenerID == listenerID,
                  self.terminalEventListenerID == listenerID,
                  self.remoteClient === client,
                  self.connectionState == .connected else { return }
            if case .subscribed(let alreadySubscribed) = ack {
                // The host accepted the re-subscribe over the event channel:
                // the stream is healthy. Count the round-trip as the liveness
                // evidence so the silence window restarts from this proof.
                self.recordTerminalEventStreamLiveness()
                // The round-trip is also positive proof of the client/host
                // connection itself; recover the visible status if a prior
                // transient RPC failure marked it unavailable, since an idle
                // terminal may never emit another event to flip it back.
                self.markMacConnectionHealthy()
                if alreadySubscribed == false {
                    // The registration had been LOST host-side (the probe just
                    // reinstalled it), so render-grid deltas emitted during the
                    // gap were never delivered and delta continuity is broken.
                    // Replay the mounted surfaces to catch up. The phone-side
                    // listener stream is intact (registration loss is a
                    // host-side condition), so no listener restart is needed.
                    MobileDebugLog.anchormux("sync.liveness probe_repaired silentMs=\(Int(silent * 1000))")
                    mobileShellLog.info("liveness probe reinstalled a lost event subscription, replaying mounted surfaces")
                    for surfaceID in self.terminalByteContinuationsBySurfaceID.keys {
                        self.requestTerminalReplay(surfaceID: surfaceID)
                    }
                    // The same registration carries `workspace.updated`, so
                    // workspace create/rename/delete events emitted during the
                    // gap were missed too; re-fetch the authoritative list.
                    self.scheduleWorkspaceListRefreshFromEvent()
                } else {
                    MobileDebugLog.anchormux("sync.liveness probe_ok silentMs=\(Int(silent * 1000))")
                }
                return
            }
            // Events may have resumed while the probe was in flight; a fresh
            // stamp means the stream already proved itself, so no recovery.
            let recheckNow = self.runtime?.now() ?? Date()
            let recheckLast = self.lastTerminalEventAt ?? recheckNow
            guard recheckNow.timeIntervalSince(recheckLast) >= Self.renderGridLivenessSilenceThreshold else {
                return
            }
            let silentMs = Int(recheckNow.timeIntervalSince(recheckLast) * 1000)
            MobileDebugLog.anchormux("sync.liveness re-subscribe silentMs=\(silentMs)")
            self.diagnosticLog?.record(DiagnosticEvent(.livenessResubscribe, ms: UInt32(clamping: silentMs)))
            mobileShellLog.info("render-grid stream silent for \(silentMs, privacy: .public)ms and subscription probe failed, re-subscribing")
            // resyncTerminalOutput(restartEventStream: true) stops the wedged
            // listener (which cancels this watchdog via stopTerminalRefreshPolling)
            // and starts a fresh subscription + watchdog, then replays every
            // surface so the phone catches up on the deltas it missed while the
            // stream was dead.
            self.resyncTerminalOutput(reason: "liveness", restartEventStream: true)
        }
    }

    /// Bounded positive-liveness probe: re-assert the event subscription and
    /// only count a completed round-trip as alive. Any failure (timeout,
    /// closed connection, rpc rejection) reports dead and lets the watchdog
    /// run its recovery.
    ///
    /// The deadline bounds the WHOLE attempt, including any Stack token work
    /// that precedes the wire write inside `sendRequest`; an unbounded hang
    /// there would otherwise pin the single-flight probe slot and disable the
    /// watchdog for the rest of the generation.
    private func probeEventSubscriptionLiveness(
        client: MobileCoreRPCClient,
        topics: [String],
        timeoutNanoseconds: UInt64
    ) async -> TerminalEventSubscriptionAck {
        let probe = Task { @MainActor [weak self] in
            await self?.requestTerminalEventSubscription(
                client: client,
                reason: "liveness_probe",
                topics: topics
            ) ?? .failed
        }
        // Bounded deadline via a one-shot DispatchSourceTimer — the same
        // sanctioned primitive the watchdog tick uses — with cancellation
        // wired to the probe's lifecycle. Cancelling the probe task surfaces
        // inside requestTerminalEventSubscription as a cancelled request ->
        // .failed.
        let deadline = DispatchSource.makeTimerSource(queue: .main)
        deadline.schedule(deadline: .now() + .nanoseconds(Int(clamping: timeoutNanoseconds)))
        deadline.setEventHandler { probe.cancel() }
        deadline.resume()
        let ack = await probe.value
        deadline.cancel()
        return ack
    }

    private func resyncTerminalOutput(
        reason: String,
        restartEventStream: Bool,
        surfaceIDs requestedSurfaceIDs: [String]? = nil
    ) {
        guard remoteClient != nil, connectionState == .connected else { return }
        if restartEventStream {
            stopTerminalRefreshPolling()
            startTerminalRefreshPolling()
        } else if terminalEventListenerTask == nil {
            startTerminalRefreshPolling()
        } else {
            refreshTerminalEventSubscription(reason: reason)
        }

        let surfaceIDs = requestedSurfaceIDs ?? Array(terminalByteContinuationsBySurfaceID.keys)
        MobileDebugLog.anchormux(
            "sync.resync reason=\(reason) restart=\(restartEventStream) surfaces=\(surfaceIDs.count)"
        )
        for surfaceID in surfaceIDs {
            requestTerminalReplay(surfaceID: surfaceID)
        }
    }

    private func handleTerminalInputResponse(_ data: Data, surfaceID: String) {
        guard hasTerminalOutputSink(surfaceID: surfaceID),
              let payload = try? MobileTerminalInputResponse.decode(data),
              let remoteSeq = payload.terminalSeq else {
            return
        }
        let localSeq = deliveredTerminalByteEndSeqBySurfaceID[surfaceID] ?? 0
        guard remoteSeq > localSeq else { return }
        if terminalOutputTransport == .renderGrid,
           terminalEventListenerTask != nil {
            let pendingSeq = pendingTerminalByteEndSeqBySurfaceID[surfaceID]
            pendingTerminalByteEndSeqBySurfaceID[surfaceID] = max(remoteSeq, pendingSeq ?? 0)
            if let pendingSeq, localSeq < pendingSeq {
                MobileDebugLog.anchormux("sync.input_seq_still_behind surface=\(surfaceID) local=\(localSeq) pending=\(pendingSeq) remote=\(remoteSeq)")
                diagnosticLog?.record(DiagnosticEvent(
                    .inputSeqBehind,
                    surface: Self.diagnosticSurfaceHandle(surfaceID),
                    a: Int(clamping: localSeq),
                    b: Int(clamping: remoteSeq),
                    c: Int(clamping: pendingSeq)
                ))
                mobileShellLog.info("terminal render-grid still behind after input surface=\(surfaceID, privacy: .public) localSeq=\(localSeq, privacy: .public) pendingSeq=\(pendingSeq, privacy: .public) remoteSeq=\(remoteSeq, privacy: .public)")
                resyncTerminalOutput(
                    reason: "input_seq_still_behind",
                    restartEventStream: true,
                    surfaceIDs: [surfaceID]
                )
            } else {
                MobileDebugLog.anchormux("sync.input_seq_wait surface=\(surfaceID) local=\(localSeq) remote=\(remoteSeq)")
                refreshTerminalEventSubscription(reason: "input_seq_wait")
            }
            return
        }
        MobileDebugLog.anchormux("sync.input_seq_behind surface=\(surfaceID) local=\(localSeq) remote=\(remoteSeq)")
        diagnosticLog?.record(DiagnosticEvent(
            .inputSeqBehind,
            surface: Self.diagnosticSurfaceHandle(surfaceID),
            a: Int(clamping: localSeq),
            b: Int(clamping: remoteSeq)
        ))
        mobileShellLog.info("terminal output behind after input surface=\(surfaceID, privacy: .public) localSeq=\(localSeq, privacy: .public) remoteSeq=\(remoteSeq, privacy: .public)")
        resyncTerminalOutput(
            reason: "input_seq_behind",
            restartEventStream: false,
            surfaceIDs: [surfaceID]
        )
    }

    private func markTerminalBytesDelivered(surfaceID: String, endSeq: UInt64) {
        let current = deliveredTerminalByteEndSeqBySurfaceID[surfaceID] ?? 0
        deliveredTerminalByteEndSeqBySurfaceID[surfaceID] = max(current, endSeq)
        if let pendingSeq = pendingTerminalByteEndSeqBySurfaceID[surfaceID],
           endSeq >= pendingSeq {
            pendingTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
            MobileDebugLog.anchormux("sync.input_seq_caught_up surface=\(surfaceID) seq=\(endSeq)")
        }
    }

    func deliverAuthoritativeTerminalRenderGrid(
        _ renderGrid: MobileTerminalRenderGridFrame,
        expectedSurfaceID: String? = nil,
        source: String
    ) {
        guard expectedSurfaceID == nil || renderGrid.surfaceID == expectedSurfaceID,
              hasTerminalOutputSink(surfaceID: renderGrid.surfaceID) else {
            return
        }
        if let deliveredSeq = deliveredTerminalByteEndSeqBySurfaceID[renderGrid.surfaceID],
           deliveredSeq > renderGrid.stateSeq {
            MobileDebugLog.anchormux(
                "sync.render_grid_stale source=\(source) surface=\(renderGrid.surfaceID) delivered=\(deliveredSeq) frame=\(renderGrid.stateSeq)"
            )
            return
        }
        markTerminalBytesDelivered(surfaceID: renderGrid.surfaceID, endSeq: renderGrid.stateSeq)
        deliverTerminalRenderGrid(renderGrid, surfaceID: renderGrid.surfaceID)
    }

    private static func terminalSnapshotReplacementBytes(_ snapshotBytes: Data) -> Data {
        var bytes = Data("\u{1B}c\u{1B}[H\u{1B}[2J\u{1B}[3J".utf8)
        bytes.append(snapshotBytes)
        return bytes
    }

    /// Whether a surface currently has an attached output stream consumer.
    private func hasTerminalOutputSink(surfaceID: String) -> Bool {
        terminalByteContinuationsBySurfaceID[surfaceID] != nil
    }

    private func registerTerminalOutput(
        surfaceID: String,
        continuation: AsyncStream<MobileTerminalOutputChunk>.Continuation
    ) {
        terminalByteContinuationsBySurfaceID[surfaceID] = continuation
        terminalOutputStreamTokensBySurfaceID[surfaceID] = UUID()
        terminalOutputQueuesBySurfaceID[surfaceID] = TerminalOutputDeliveryQueue()
        deliveredTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        pendingTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        #if DEBUG
        mobileShellLog.info("CMUX_REPLAY register sink surface=\(surfaceID, privacy: .public) connected=\(self.connectionState == .connected, privacy: .public) hasClient=\(self.remoteClient != nil, privacy: .public) workspaceCount=\(self.workspaces.count, privacy: .public)")
        #endif
        requestTerminalReplay(surfaceID: surfaceID)
    }

    private func unregisterTerminalOutput(surfaceID: String) {
        terminalByteContinuationsBySurfaceID.removeValue(forKey: surfaceID)
        terminalOutputStreamTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalOutputQueuesBySurfaceID.removeValue(forKey: surfaceID)
        terminalScrollQueueTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalScrollQueuesBySurfaceID.removeValue(forKey: surfaceID)
        terminalScrollbackPrefetchStatesBySurfaceID.removeValue(forKey: surfaceID)
        deliveredTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        pendingTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        // Tell the Mac this device is no longer viewing the surface so it stops
        // pinning the shared grid to our viewport and clears the macOS border.
        clearTerminalViewport(surfaceID: surfaceID)
    }

    /// The output byte stream for a terminal surface.
    ///
    /// Obtaining the stream arms a cold-attach replay so the surface catches up
    /// to current state; ending iteration (or cancelling the consuming task)
    /// unregisters the surface and clears its viewport pin on the Mac.
    /// - Parameter surfaceID: The terminal surface identifier.
    /// - Returns: An `AsyncStream` of output byte chunks.
    public func terminalOutputStream(surfaceID: String) -> AsyncStream<MobileTerminalOutputChunk> {
        AsyncStream { continuation in
            registerTerminalOutput(surfaceID: surfaceID, continuation: continuation)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.unregisterTerminalOutput(surfaceID: surfaceID)
                }
            }
        }
    }

    /// Report this device's natural terminal grid to the Mac and return the
    /// effective grid the Mac computed (the smallest across all attached
    /// devices, capped to the Mac pane). The caller pins its libghostty surface
    /// to that grid so every device renders the same cols×rows with a viewport
    /// border around the live area (tmux-style shared resize).
    public func updateTerminalViewport(
        surfaceID: String,
        columns: Int,
        rows: Int
    ) async -> (columns: Int, rows: Int)? {
        guard columns > 0, rows > 0,
              let client = remoteClient,
              let workspaceID = workspaceID(forTerminalID: surfaceID) else {
            return nil
        }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.terminal.viewport",
                params: [
                    "workspace_id": workspaceID.rawValue,
                    "surface_id": surfaceID,
                    "client_id": clientID,
                    "viewport_columns": columns,
                    "viewport_rows": rows,
                ]
            )
            let data = try await client.sendRequest(request)
            guard remoteClient === client else { return nil }
            guard let payload = try? MobileTerminalViewportResponse.decode(data),
                  let grid = payload.effectiveGrid else {
                return nil
            }
            return (grid.columns, grid.rows)
        } catch {
            mobileShellLog.error("viewport report failed surface=\(surfaceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Tell the Mac to drop this device's viewport pin for a surface (on
    /// detach). Fire-and-forget; the Mac also clears on connection close.
    public func clearTerminalViewport(surfaceID: String) {
        guard let client = remoteClient,
              let workspaceID = workspaceID(forTerminalID: surfaceID) else {
            return
        }
        let id = clientID
        Task { @MainActor in
            let request = try? MobileCoreRPCClient.requestData(
                method: "mobile.terminal.viewport",
                params: [
                    "workspace_id": workspaceID.rawValue,
                    "surface_id": surfaceID,
                    "client_id": id,
                    "clear": true,
                ]
            )
            guard let request else { return }
            _ = try? await client.sendRequest(request)
        }
    }

    /// Cold-attach/self-heal replay. Prefer the Mac's bounded render-grid
    /// snapshot, replacing the local iOS terminal state before live bytes
    /// resume. The VT snapshot and raw byte ring remain fallbacks, but neither
    /// is the target architecture: a byte tail is not a complete screen state
    /// for TUIs, and a VT export is still a replay stream rather than state.
    private func requestTerminalReplay(surfaceID: String) {
        guard let client = remoteClient else {
            #if DEBUG
            mobileShellLog.error("CMUX_REPLAY skip surface=\(surfaceID, privacy: .public) reason=no_remote_client")
            #endif
            return
        }
        guard let workspaceID = workspaceID(forTerminalID: surfaceID) else {
            #if DEBUG
            mobileShellLog.error("CMUX_REPLAY skip surface=\(surfaceID, privacy: .public) reason=workspace_not_found")
            #endif
            return
        }
        guard !terminalReplaySurfaceIDsInFlight.contains(surfaceID) else {
            #if DEBUG
            mobileShellLog.info("CMUX_REPLAY skip surface=\(surfaceID, privacy: .public) reason=in_flight")
            #endif
            return
        }
        terminalReplaySurfaceIDsInFlight.insert(surfaceID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.terminalReplaySurfaceIDsInFlight.remove(surfaceID) }
            do {
                let request = try MobileCoreRPCClient.requestData(
                    method: "mobile.terminal.replay",
                    params: [
                        "workspace_id": workspaceID.rawValue,
                        "surface_id": surfaceID,
                    ]
                )
                let data = try await client.sendRequest(request)
                guard self.remoteClient === client else { return }
                let payload = try? MobileTerminalReplayResponse.decode(data)
                let bytes = payload?.dataBase64.flatMap { Data(base64Encoded: $0) }
                let snapshotBytes = payload?.snapshotBase64.flatMap { Data(base64Encoded: $0) }
                let decodedRenderGrid = payload?.renderGrid
                let renderGrid = decodedRenderGrid?.surfaceID == surfaceID ? decodedRenderGrid : nil
                let replaySeq = renderGrid?.stateSeq ?? payload?.sequence
                #if DEBUG
                let seq = replaySeq ?? 0
                let cols = payload?.columns ?? -1
                let rows = payload?.rows ?? -1
                mobileShellLog.info("CMUX_REPLAY response surface=\(surfaceID, privacy: .public) byteCount=\(bytes?.count ?? -1, privacy: .public) snapshotBytes=\(snapshotBytes?.count ?? -1, privacy: .public) renderGrid=\(renderGrid != nil, privacy: .public) seq=\(seq, privacy: .public) macGrid=\(cols, privacy: .public)x\(rows, privacy: .public) hasSink=\(self.hasTerminalOutputSink(surfaceID: surfaceID), privacy: .public)")
                #endif
                if let replaySeq,
                   let deliveredSeq = self.deliveredTerminalByteEndSeqBySurfaceID[surfaceID],
                   deliveredSeq > replaySeq {
                    MobileDebugLog.anchormux("CMUX_REPLAY stale surface=\(surfaceID) delivered=\(deliveredSeq) replay=\(replaySeq)")
                    return
                }
                let deliverBytes: Data?
                if let renderGrid {
                    deliverBytes = nil
                    MobileDebugLog.anchormux("CMUX_REPLAY render_grid surface=\(surfaceID) spans=\(renderGrid.rowSpans.count) seq=\(renderGrid.stateSeq)")
                } else if let snapshotBytes, !snapshotBytes.isEmpty {
                    deliverBytes = Self.terminalSnapshotReplacementBytes(snapshotBytes)
                    MobileDebugLog.anchormux("CMUX_REPLAY snapshot surface=\(surfaceID) bytes=\(snapshotBytes.count) seq=\(replaySeq ?? 0)")
                } else {
                    deliverBytes = bytes
                    MobileDebugLog.anchormux("CMUX_REPLAY raw_tail surface=\(surfaceID) bytes=\(bytes?.count ?? -1) seq=\(replaySeq ?? 0)")
                }
                if let replaySeq {
                    self.markTerminalBytesDelivered(surfaceID: surfaceID, endSeq: replaySeq)
                }
                if let renderGrid {
                    self.deliverTerminalRenderGrid(renderGrid, surfaceID: surfaceID)
                    return
                }
                guard let deliverBytes, !deliverBytes.isEmpty else {
                    return
                }
                self.deliverTerminalBytes(deliverBytes, surfaceID: surfaceID)
            } catch {
                mobileShellLog.error("CMUX_REPLAY failed surface=\(surfaceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
                // The replay request is the view-only/foreground-resume path. A
                // definitive auth failure here (after the RPC layer's
                // force-refresh-and-retry already gave up) must drive the re-auth
                // prompt instead of silently leaving a stale frame.
                guard self.remoteClient === client else { return }
                _ = self.disconnectForAuthorizationFailureIfNeeded(error)
            }
        }
    }

    private func handleTerminalRenderGridEvent(_ event: MobileEventEnvelope) {
        guard let json = event.payloadJSON else {
            return
        }
        // The frame may arrive nested under `render_grid` or as the bare payload;
        // try the wrapper first, then fall back to decoding the whole payload.
        let renderGridDTO = try? MobileTerminalRenderGridEvent.decode(json)
        guard let renderGrid = renderGridDTO?.frame ?? (try? MobileTerminalRenderGridFrame.decode(json)),
              hasTerminalOutputSink(surfaceID: renderGrid.surfaceID) else {
            return
        }
        #if DEBUG
        mobileShellLog.info("CMUX_REPLAY live render_grid surface=\(renderGrid.surfaceID, privacy: .public) full=\(renderGrid.full, privacy: .public) spans=\(renderGrid.rowSpans.count, privacy: .public) cleared=\(renderGrid.clearedRows.count, privacy: .public) seq=\(renderGrid.stateSeq, privacy: .public) hasSink=true")
        #endif
        deliverAuthoritativeTerminalRenderGrid(renderGrid, source: "event")
    }

    private func handleNotificationDismissedEvent(_ event: MobileEventEnvelope) async {
        guard
            let json = event.payloadJSON,
            let payload = MobileNotificationDismissedEvent.decode(json)
        else {
            return
        }
        if !payload.ids.isEmpty {
            await clearDeliveredNotifications(ids: payload.ids)
        }
        if let unreadCount = payload.unreadCount {
            applyAuthoritativeUnreadBadge(unreadCount)
        }
    }

    private func handleNotificationBadgeEvent(_ event: MobileEventEnvelope) {
        guard
            let json = event.payloadJSON,
            let payload = MobileNotificationBadgeEvent.decode(json),
            let unreadCount = payload.unreadCount
        else {
            return
        }
        applyAuthoritativeUnreadBadge(unreadCount)
    }

    private func handleTerminalBytesEvent(_ event: MobileEventEnvelope) {
        guard
            let json = event.payloadJSON,
            let payload = MobileTerminalBytesEvent.decode(json)
        else {
            return
        }
        let surfaceID = payload.surfaceID
        let bytes = payload.bytes
        #if DEBUG
        let debugSeq = payload.sequence ?? 0
        mobileShellLog.info("CMUX_REPLAY live bytes surface=\(surfaceID, privacy: .public) byteCount=\(bytes.count, privacy: .public) seq=\(debugSeq, privacy: .public) hasSink=\(self.hasTerminalOutputSink(surfaceID: surfaceID), privacy: .public)")
        #endif
        guard let seq = payload.sequence else {
            deliverTerminalBytes(bytes, surfaceID: surfaceID)
            return
        }
        let endSeq = seq &+ UInt64(bytes.count)
        if let deliveredSeq = deliveredTerminalByteEndSeqBySurfaceID[surfaceID] {
            if seq > deliveredSeq {
                MobileDebugLog.anchormux("sync.byte_gap surface=\(surfaceID) delivered=\(deliveredSeq) next=\(seq)")
                diagnosticLog?.record(DiagnosticEvent(
                    .byteGap,
                    surface: Self.diagnosticSurfaceHandle(surfaceID),
                    a: Int(clamping: deliveredSeq),
                    b: Int(clamping: seq)
                ))
                mobileShellLog.info("terminal byte gap surface=\(surfaceID, privacy: .public) deliveredSeq=\(deliveredSeq, privacy: .public) nextSeq=\(seq, privacy: .public)")
                resyncTerminalOutput(
                    reason: "seq_gap",
                    restartEventStream: false,
                    surfaceIDs: [surfaceID]
                )
                return
            }
            if endSeq <= deliveredSeq {
                return
            }
            let overlap = deliveredSeq - seq
            let deliverBytes = Data(bytes.dropFirst(Int(overlap)))
            deliverTerminalBytes(deliverBytes, surfaceID: surfaceID)
            markTerminalBytesDelivered(surfaceID: surfaceID, endSeq: endSeq)
            return
        }
        deliverTerminalBytes(bytes, surfaceID: surfaceID)
        markTerminalBytesDelivered(surfaceID: surfaceID, endSeq: endSeq)
    }

    private func scheduleWorkspaceListRefreshFromEvent() {
        guard remoteClient != nil else { return }
        // Keep the event path's "latest event wins" semantics: a `workspace.updated`
        // arriving mid-fetch restarts the fetch so the applied list reflects the
        // change the Mac pushed *after* this fetch started. This cancels only the
        // event-driven task handle; the user pull-to-refresh runs on its own
        // (``pullToRefreshTask``) so an event can never truncate its spinner.
        workspaceListRefreshTask?.cancel()
        workspaceListRefreshTask = Task { @MainActor [weak self] in
            defer { self?.workspaceListRefreshTask = nil }
            await self?.reloadWorkspaceListFromMac()
        }
    }

    /// Re-fetch the authoritative workspace list from the connected Mac and apply
    /// it, awaiting the round-trip to completion.
    ///
    /// This is the single shared re-sync the `workspace.updated` event refresh and
    /// the user's pull-to-refresh both funnel through, so the list never has two
    /// divergent fetch paths. A no-op when not connected. Errors (offline / wedged
    /// transport) are caught and logged, leaving the existing list intact, because
    /// ``applyRemoteWorkspaceList(_:preferActiveTicketTarget:mergeExistingWorkspaces:)``
    /// runs only on a successful decode.
    private func reloadWorkspaceListFromMac() async {
        guard let client = remoteClient else { return }
        do {
            let request = try MobileCoreRPCClient.requestData(method: "mobile.workspace.list", params: [:])
            let data = try await client.sendRequest(
                request,
                timeoutNanoseconds: runtime?.rpcRequestTimeoutNanoseconds
            )
            let response = try MobileSyncWorkspaceListResponse.decode(data)
            guard remoteClient === client, connectionState == .connected else { return }
            applyRemoteWorkspaceList(response, preferActiveTicketTarget: false)
            syncSelectedTerminalForWorkspace()
        } catch {
            mobileShellLog.error("workspace list event refresh failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// Pull-to-refresh entry point: re-sync the workspace list from the connected
    /// Mac, awaiting real completion so the system refresh spinner reflects the
    /// actual round-trip (and ends gracefully on failure, leaving the list intact).
    ///
    /// Runs on its own ``pullToRefreshTask`` handle, separate from the
    /// event-driven ``workspaceListRefreshTask`` that a `workspace.updated` push
    /// cancels and restarts, so a background event can never truncate the pull's
    /// spinner by cancelling the task it is awaiting. Rapid repeated pulls coalesce
    /// onto the single in-flight pull task rather than stacking duplicate
    /// `mobile.workspace.list` calls. Returns immediately when not connected, so an
    /// offline pull cannot hang the spinner on a transport timeout.
    public func refreshWorkspaces() async {
        guard connectionState == .connected, remoteClient != nil else { return }
        if let inFlight = pullToRefreshTask {
            await inFlight.value
            return
        }
        let task = Task { @MainActor [weak self] in
            defer { self?.pullToRefreshTask = nil }
            await self?.reloadWorkspaceListFromMac()
        }
        pullToRefreshTask = task
        await task.value
    }

    private func stopTerminalRefreshPolling() {
        terminalEventListenerTask?.cancel()
        terminalEventListenerTask = nil
        terminalEventListenerID = nil
        terminalSubscriptionStartTask?.cancel()
        terminalSubscriptionStartTask = nil
        stopRenderGridLivenessWatchdog(listenerID: nil)
    }

    private func setSelectedWorkspaceID(_ id: MobileWorkspacePreview.ID?) {
        selectedWorkspaceID = id
    }

    private func applyRemoteWorkspaceList(
        _ response: MobileSyncWorkspaceListResponse,
        preferActiveTicketTarget: Bool = false,
        mergeExistingWorkspaces: Bool = false
    ) {
        let remoteWorkspaces = remoteWorkspacesPreservingSnapshots(from: response)
        if mergeExistingWorkspaces {
            var mergedWorkspaces = workspaces
            for remoteWorkspace in remoteWorkspaces {
                if let existingIndex = mergedWorkspaces.firstIndex(where: { $0.id == remoteWorkspace.id }) {
                    mergedWorkspaces[existingIndex] = remoteWorkspace
                } else {
                    mergedWorkspaces.append(remoteWorkspace)
                }
            }
            workspaces = mergedWorkspaces
        } else {
            workspaces = remoteWorkspaces
        }
        // Group sections always reflect the latest full response (never merged):
        // a merge path is a single-entry create/refresh that omits groups, so
        // applying its empty groups array would wrongly clear the sections. Only a
        // full-list response (the non-merge path, which the event-driven refresh
        // and initial sync use) carries authoritative group state.
        if !mergeExistingWorkspaces {
            workspaceGroups = response.groups.map { MobileWorkspaceGroupPreview(remote: $0) }
        }
        if preferActiveTicketTarget, selectActiveTicketTargetIfAvailable() {
            return
        }
        if let selectedWorkspaceID,
           workspaces.contains(where: { $0.id == selectedWorkspaceID }) {
            syncSelectedTerminalForWorkspace()
            return
        }
        setSelectedWorkspaceID(
            response.workspaces.first(where: \.isSelected)
                .map { MobileWorkspacePreview.ID(rawValue: $0.id) }
                ?? workspaces.first?.id
        )
        syncSelectedTerminalForWorkspace()
    }

    private func remoteWorkspacesPreservingSnapshots(
        from response: MobileSyncWorkspaceListResponse
    ) -> [MobileWorkspacePreview] {
        response.workspaces.map { remoteWorkspace in
            var workspace = MobileWorkspacePreview(remote: remoteWorkspace)
            guard let existingWorkspace = workspaces.first(where: { $0.id == workspace.id }) else {
                return workspace
            }
            workspace.terminals = workspace.terminals.map { remoteTerminal in
                guard let existingTerminal = existingWorkspace.terminals.first(where: { $0.id == remoteTerminal.id }) else {
                    return remoteTerminal
                }
                var terminal = remoteTerminal
                terminal.viewportFit = existingTerminal.viewportFit
                return terminal
            }
            return workspace
        }
    }

    private func selectActiveTicketTargetIfAvailable() -> Bool {
        guard let activeTicket else {
            return false
        }
        let ticketWorkspaceID = MobileWorkspacePreview.ID(rawValue: activeTicket.workspaceID)
        guard let workspace = workspaces.first(where: { $0.id == ticketWorkspaceID }) else {
            return false
        }
        setSelectedWorkspaceID(ticketWorkspaceID)
        if let ticketTerminalID = activeTicket.terminalID.map(MobileTerminalPreview.ID.init(rawValue:)),
           workspace.terminals.contains(where: { $0.id == ticketTerminalID }) {
            selectedTerminalID = ticketTerminalID
        } else {
            syncSelectedTerminalForWorkspace()
        }
        return true
    }

    func disconnectForAuthorizationFailureIfNeeded(_ error: any Error) -> Bool {
        guard Self.shouldDisconnectForAuthorizationFailure(error) else {
            return false
        }
        let category = MobilePairingFailureCategory.classify(error: error, route: activeRoute)
        // Not `applyPairingFailure`: this path also sets `connectionRequiresReauth`,
        // uses fallback-if-empty, and gates analytics on `pairingAttemptMethod` so
        // live-connection auth evictions never emit `ios_pairing_failed`.
        connectionError = category.message.isEmpty
            ? L10n.string("mobile.pairing.runtimeUnavailable", defaultValue: "Could not connect to your computer.")
            : category.message
        connectionErrorGuidance = category.guidance
        connectionRequiresReauth = true
        connectionState = .disconnected
        macConnectionStatus = .unavailable
        clearRemoteConnectionContext()
        // Only emits while a pairing attempt is in flight: `recordPairingFailed`
        // no-ops once `pairingAttemptMethod` is nil (cleared on success and by
        // `invalidatePairingAttempt`), so live-connection auth failures that
        // also route through here never emit `ios_pairing_failed`.
        recordPairingFailed(reason: category.analyticsReason, phase: "auth")
        return true
    }

    private static func shouldDisconnectForAuthorizationFailure(_ error: any Error) -> Bool {
        guard let connectionError = error as? MobileShellConnectionError else {
            return false
        }
        switch connectionError {
        case .attachTicketExpired, .authorizationFailed, .accountMismatch, .insecureManualRoute:
            return true
        case let .rpcError(code, message):
            let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let normalizedCode,
               ["unauthorized", "forbidden", "invalid_token", "token_expired", "expired_token", "auth_required"].contains(normalizedCode) {
                return true
            }
            let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalizedMessage.contains("unauthorized")
                || normalizedMessage.contains("forbidden")
                || normalizedMessage.contains("invalid token")
                || normalizedMessage.contains("expired token")
                || normalizedMessage.contains("token expired")
        case .invalidResponse, .connectionClosed, .requestTimedOut:
            return false
        }
    }

    private static func routeSortsBefore(_ left: CmxAttachRoute, _ right: CmxAttachRoute) -> Bool {
        if left.priority == right.priority {
            return left.id < right.id
        }
        return left.priority < right.priority
    }

    private func applyPreviewTicket(_ ticket: CmxAttachTicket, route: CmxAttachRoute) {
        let terminalID = ticket.terminalID ?? "attached-terminal"
        workspaces = [
            MobileWorkspacePreview(
                id: .init(rawValue: ticket.workspaceID),
                name: L10n.string("mobile.preview.attachedWorkspaceName", defaultValue: "Attached Workspace"),
                terminals: [
                    MobileTerminalPreview(
                        id: .init(rawValue: terminalID),
                        name: L10n.string("mobile.preview.attachedTerminalName", defaultValue: "Attached Terminal")
                    ),
                ]
            ),
        ]
        selectedWorkspaceID = workspaces.first?.id
        selectedTerminalID = workspaces.first?.terminals.first?.id
    }
}

private struct MobileTerminalViewportKey: Hashable, Sendable {
    var workspaceID: MobileWorkspacePreview.ID
    var terminalID: MobileTerminalPreview.ID
}

private struct MobileManualAttachTicketCreateResponse: Decodable, Sendable {
    var ticket: CmxAttachTicket

    static func decode(_ data: Data) throws -> MobileManualAttachTicketCreateResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MobileManualAttachTicketCreateResponse.self, from: data)
    }
}

private extension MobileShellComposite {
    static func mobileShellVersionDisplay(
        version: String?,
        build: String?,
        compatibilityVersion: Int?
    ) -> String {
        let version = version ?? mobileShellCompatibilityDisplay(compatibilityVersion)
        guard let build = mobileShellNormalizedNonEmpty(build) else { return version }
        return "\(version) (\(build))"
    }

    static func mobileShellCompatibilityDisplay(_ compatibilityVersion: Int?) -> String {
        guard let compatibilityVersion, compatibilityVersion > 0 else {
            return L10n.string(
                "mobile.pairing.compatibilityUnknown",
                defaultValue: "unknown compatibility"
            )
        }
        return String(
            format: L10n.string(
                "mobile.pairing.compatibilityDisplayFormat",
                defaultValue: "compatibility %@"
            ),
            "\(compatibilityVersion)"
        )
    }

    static func mobileShellNormalizedEmail(_ value: String?) -> String? {
        mobileShellNormalizedNonEmpty(value)?.lowercased()
    }

    static func mobileShellNormalizedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

private extension CmxAttachTicket {
    func constrainingRoutes(
        to routes: [CmxAttachRoute],
        fallbackDisplayName: String
    ) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: workspaceID,
            terminalID: terminalID,
            macDeviceID: macDeviceID,
            macDisplayName: macDisplayName ?? fallbackDisplayName,
            macUserEmail: macUserEmail,
            macUserID: macUserID,
            macPairingCompatibilityVersion: macPairingCompatibilityVersion,
            macAppVersion: macAppVersion,
            macAppBuild: macAppBuild,
            routes: routes,
            expiresAt: expiresAt,
            authToken: authToken
        )
    }

}

private extension MobileWorkspacePreview {
    var preferredTerminal: MobileTerminalPreview? {
        terminals.first { $0.isReady && $0.isFocused }
            ?? terminals.first { $0.isReady }
            ?? terminals.first { $0.isFocused }
            ?? terminals.first
    }

    var hasReadyTerminal: Bool {
        terminals.contains(where: \.isReady)
    }
}
private extension MobileShellComposite {
    /// The name shown for the Mac until `mobile.host.status` reports the real
    /// one: the ticket's display name, then its device id, then the dialed
    /// route's host (a minimal v2 pairing code carries neither name nor id,
    /// so the Tailscale hostname is the best available placeholder).
    func placeholderHostName(
        for ticket: CmxAttachTicket,
        firstRoute: CmxAttachRoute
    ) -> String {
        if let name = ticket.macDisplayName, !name.isEmpty {
            return name
        }
        if !ticket.macDeviceID.isEmpty {
            return ticket.macDeviceID
        }
        if case let .hostPort(host, _) = firstRoute.endpoint {
            return host
        }
        return ""
    }
}
