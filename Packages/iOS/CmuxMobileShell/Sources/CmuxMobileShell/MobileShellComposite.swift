public import CMUXMobileCore
public import CmuxAgentChat
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
        case hybrid
        case renderGrid
        case rawBytes

        var eventTopics: [String] {
            switch self {
            case .hybrid:
                return ["workspace.updated", "terminal.bytes", "terminal.render_grid", "terminal.set_font", "notification.dismissed", "notification.badge"]
            case .renderGrid:
                return ["workspace.updated", "terminal.render_grid", "terminal.set_font", "notification.dismissed", "notification.badge"]
            case .rawBytes:
                return ["workspace.updated", "terminal.bytes", "terminal.set_font", "notification.dismissed", "notification.badge"]
            }
        }

        var debugName: String {
            switch self {
            case .hybrid:
                return "hybrid"
            case .renderGrid:
                return "render_grid"
            case .rawBytes:
                return "raw_bytes"
            }
        }

        var usesRenderGrid: Bool {
            switch self {
            case .hybrid, .renderGrid:
                return true
            case .rawBytes:
                return false
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
    /// Whether the current attach ticket has a non-empty auth token and has not expired.
    public var hasActiveUnexpiredAttachTicket: Bool {
        guard let activeTicket,
              activeTicket.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        return Self.attachTicketIsUnexpired(activeTicket, now: runtime?.now() ?? Date())
    }
    /// User-entered pairing code or pairing URL text for the current connection attempt.
    public var pairingCode: String
    /// The per-Mac source of truth for workspaces, keyed by `macDeviceID` (or
    /// ``foregroundAnonymousKey`` for an anonymous/manual-ticket foreground). Every
    /// connected Mac writes only its own entry; ``workspaces`` and
    /// ``workspaceGroups`` are pure derivations over this map
    /// (``MobileWorkspaceAggregation``), never assigned directly, so a stale or
    /// half-merged aggregate is unrepresentable. Transport-agnostic: fed by N
    /// direct phone->Mac connections today, one phone->Durable Object stream later.
    var workspacesByMac: [String: MacWorkspaceState] = [:] {
        didSet { recomputeDerivedWorkspaceState() }
    }
    private let workspaceAggregation = MobileWorkspaceAggregation()
    /// The flat aggregated workspace list the UI renders. A materialized
    /// derivation of ``workspacesByMac``: only ``recomputeDerivedWorkspaceState``
    /// assigns it, so it is never independently mutated.
    public private(set) var workspaces: [MobileWorkspacePreview] = [] {
        didSet {
            workspaceTopologyVersion &+= 1
            prunePendingAttachmentsForMissingTerminals()
        }
    }
    /// Bumped on every ``workspaces`` mutation: a cheap "lists may have
    /// changed" signal (e.g. for retrying a parked notification deep link).
    public private(set) var workspaceTopologyVersion: UInt64 = 0
    /// Last authoritative chat-session snapshots, keyed by the workspace row id the UI renders.
    var chatSessionSnapshotsByWorkspaceID: [String: [ChatSessionDescriptor]] = [:]
    /// The group sections the UI renders. A materialized derivation of
    /// ``workspacesByMac`` (currently the foreground Mac's groups). Each group's
    /// `isCollapsed` reflects this device's choice (see ``groupCollapseStore``),
    /// not the Mac's live value.
    public internal(set) var workspaceGroups: [MobileWorkspaceGroupPreview] = []

    /// The distinct per-Mac color index map (the SAME assignment the aggregated
    /// workspace avatars use), so the Computers screen can color each Mac's row to
    /// match its workspaces. Keyed by `macDeviceID`.
    public var machineColorIndex: [String: Int] {
        workspaceAggregation.machineColorIndex(statesByMac: workspacesByMac)
    }

    public var macConnectionStatuses: [String: MobileMacConnectionStatus] {
        var result = workspacesByMac.reduce(into: [String: MobileMacConnectionStatus]()) { statuses, entry in
            if !entry.key.isEmpty { statuses[entry.key] = entry.value.status }
        }
        for (representativeID, aliases) in pairedMacAliasIDsByRepresentativeID {
            let aliasStatuses = aliases.compactMap { result[$0] }
            if aliasStatuses.contains(.connected) {
                result[representativeID] = .connected
            } else if aliasStatuses.contains(.reconnecting) {
                result[representativeID] = .reconnecting
            } else if aliasStatuses.contains(.unavailable) {
                result[representativeID] = .unavailable
            }
        }
        return result
    }

    /// Reachability prober for the Computers screen, injected via `init` (default
    /// = production network pinger) so the UI depends only on the core
    /// ``CmxRoutePinging`` seam and tests can pass a fake. `@ObservationIgnored`:
    /// stateless infrastructure, not observed state.
    @ObservationIgnored
    private let routePinger: any CmxRoutePinging

    /// Probe whether the phone can reach this route right now (a direct TCP
    /// connect, independent of the live subscription). See ``CmxRoutePinging``.
    public func pingRoute(_ route: CmxAttachRoute) async -> CmxRoutePingResult {
        await routePinger.ping(route)
    }

    /// Device-local collapse state for workspace groups (per-device UI preference:
    /// collapsing on the phone must not collapse on the Mac). Seeded once from the
    /// Mac, then phone-owned. `@ObservationIgnored` (views read `workspaceGroups`);
    /// injected so tests/previews can pass a suite-scoped `UserDefaults`.
    @ObservationIgnored var groupCollapseStore: MobileWorkspaceGroupCollapseStore
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
    /// Guards the WHOLE composer submit (``submitComposer()``: images + text)
    /// against re-entrancy. The Send button stays enabled while the first image
    /// RPC awaits (attachments are cleared only on ack), so a second tap would
    /// otherwise start another submit capturing the same still-staged
    /// attachments and re-upload them. Distinct from
    /// ``isSubmittingComposerInput`` (which guards only the inner text paste):
    /// this spans the entire image-then-text run. Not observed: it gates an
    /// async flow, not view state.
    @ObservationIgnored private var isSubmittingComposer = false
    /// Pending image attachments per terminal, keyed by terminal id so switching
    /// terminals keeps each draft's own attachments (mirroring how the text draft
    /// is keyed). Observed so the composer's chip row re-renders on add/remove.
    /// Sent in order on the next submit and then cleared for that terminal.
    private var pendingAttachmentsByTerminalID: [String: [MobilePendingAttachment]] = [:]

    /// Max number of staged attachments per terminal. Enforced in
    /// ``addPendingAttachment(_:format:forTerminalID:)`` against the CURRENT
    /// staged set at mutation time so the check+insert is atomic on the main
    /// actor: two concurrent picker batches that each snapshot the same starting
    /// budget cannot both append past the cap, because the second add re-reads
    /// the (already-grown) staged set. The view may pre-filter for
    /// responsiveness, but the store is the authoritative cap.
    public nonisolated static let maxPendingAttachmentCount = 10
    /// Total encoded-bytes budget across one terminal's staged attachments.
    /// Enforced in the same atomic add path as the count cap so a run of large
    /// photos (or two racing batches) cannot balloon observable state past the
    /// budget regardless of the count.
    public nonisolated static let maxPendingAttachmentTotalBytes = 32 * 1024 * 1024
    /// Per-image encoded-bytes cap. An add whose single image exceeds this is
    /// rejected outright (the view bounds the encode below this, but the store
    /// re-enforces it as the single source of truth).
    public nonisolated static let maxPendingAttachmentImageBytes = 8 * 1024 * 1024
    /// GLOBAL encoded-bytes budget summed across EVERY terminal's staged set, not
    /// just the target's. The per-terminal cap bounds one draft, but each live
    /// terminal carries its own per-terminal budget, so staging photos across many
    /// terminals/workspaces without sending grows linearly with terminal count and
    /// can OOM. This global cap is enforced in the same atomic add path (on
    /// @MainActor, summing across all keys at insert time is consistent) as a hard
    /// reject: an add that would push the all-terminals total past this is dropped,
    /// in addition to the per-terminal checks. 64 MB tolerates a couple of full
    /// per-terminal drafts while still bounding the process.
    public nonisolated static let maxPendingAttachmentTotalBytesAllTerminals = 64 * 1024 * 1024
    /// GLOBAL count budget summed across EVERY terminal's staged set. Bounds the
    /// total number of staged images process-wide regardless of how they are spread
    /// across terminals, enforced as a hard reject in the same atomic add path.
    public nonisolated static let maxPendingAttachmentCountAllTerminals = 20
    /// Monotonic token bumped by ``signOut()``, identifying the current signed-in
    /// session. The composer's photo-staging path captures it before its
    /// (off-main) load + encode and re-checks it just before mutating the store:
    /// a sign-out that lands while a photo is in flight bumps the token, so the
    /// stale continuation is dropped instead of re-staging the previous user's
    /// photo bytes under a terminal id the next account may reuse. Not observed:
    /// it gates an async hand-back, not view state.
    @ObservationIgnored private var signInGeneration = 0
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

    let runtime: (any MobileSyncRuntime)?
    let pairedMacStore: (any MobilePairedMacStoring)?
    private let pairedMacRestoreBoundary: PairedMacRestoreBoundary?
    /// Best-effort, team-scoped lookup of fresher attach routes from the device
    /// registry. Optional and failure-tolerant: when `nil` or unreachable,
    /// reconnect uses the locally persisted paired-Mac routes, so pairing
    /// survives the cloud registry being down.
    private let deviceRegistry: (any DeviceRegistryRefreshing)?
    /// Live presence subscription (the `workers/presence` Durable Object edge).
    /// Optional and failure-tolerant like the registry: when `nil` or down, the
    /// device tree simply keeps its registry "last seen" hints.
    private let presence: (any PresenceSubscribing)?
    let identityProvider: (any MobileIdentityProviding)?
    let teamIDProvider: @Sendable () async -> String?
    private let reachability: any ReachabilityProviding
    // Internal (not private): used by the dismiss-sync extension file.
    let deliveredNotificationClearer: any DeliveredNotificationClearing
    /// Durable outbox for phone→Mac dismissals.
    let pendingDismissQueue: PendingNotificationDismissQueue
    private let pairingHintDefaults: UserDefaults
    private let multiMacAggregationDefaults: UserDefaults
    let forgottenMacStore: any PairedMacForgottenStoring
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
    let connectAttemptRegistry = MobileRPCConnectAttemptRegistry()
    let stackTokenGate = RPCStackTokenGate()
    let stackTokenForceRefreshGate = RPCStackTokenGate()
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
    /// `remoteClient` narrowed for `MobileShellComposite+AgentChat.swift`.
    var remoteClientForAgentChat: MobileCoreRPCClient? { remoteClient }
    /// Identity token that changes when the paired Mac chat event source is rebuilt.
    public var agentChatEventSourceIdentity: String { chatEventSourceGeneration.uuidString }
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
    private var pushedRouteSyncTask: Task<Void, Never>?
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
    private var chatEventSourceGeneration: UUID
    /// The per-Mac connection pool (P2 of the multi-Mac work), keyed by
    /// `macDeviceID`. Today it tracks the single foreground connection; P3 adds
    /// read-only connections to the user's other Macs so every connected Mac's
    /// workspaces can be aggregated. `foregroundMacDeviceID` is the Mac whose
    /// connection drives terminal I/O and the connected UI.
    private var connections: [String: MacConnection] = [:]
    var foregroundMacDeviceID: String? {
        didSet { recomputeDerivedWorkspaceState() }
    }
    /// Persistent read-only connections to the NON-foreground Macs, each holding a
    /// live `workspace.updated` subscription that keeps its ``workspacesByMac``
    /// entry current (slice 3). Best-effort and fully additive: any failure tears
    /// the entry down and the pull-to-refresh / foreground re-aggregate path
    /// remains as the fallback. Keyed by `macDeviceID`. Today these are N direct
    /// phone->Mac connections; the same per-Mac entries would be fed by one
    /// phone->Durable Object stream in the planned end-state.
    var secondaryMacSubscriptions: [String: SecondaryMacSubscription] = [:]
    /// The in-flight multi-Mac aggregation pass, tracked so sign-out / account
    /// switch can cancel it; its scope guards then bail before any cross-account
    /// write. Replaced (cancelling the prior) on each scheduled pass.
    private var secondaryAggregationTask: Task<Void, Never>?
    /// Bumped on Stack team switches so every aggregation caller, including
    /// direct pull-to-refresh calls that are not owned by
    /// ``secondaryAggregationTask``, can reject old-team results after awaits.
    var secondaryAggregationScopeGeneration = 0
    private var reportedViewportSizesByTerminalKey: [MobileTerminalViewportKey: MobileTerminalViewportSize]
    private var deliveredTerminalByteEndSeqBySurfaceID: [String: UInt64]
    private var pendingTerminalByteEndSeqBySurfaceID: [String: UInt64]
    private var terminalActiveScreenBySurfaceID: [String: MobileTerminalRenderGridFrame.Screen]
    private var terminalReplaySurfaceIDsInFlight: Set<String>
    private var terminalOutputTransport: TerminalOutputTransport
    var terminalByteContinuationsBySurfaceID: [String: AsyncStream<MobileTerminalOutputChunk>.Continuation]
    var terminalOutputStreamTokensBySurfaceID: [String: UUID]
    var terminalOutputQueuesBySurfaceID: [String: TerminalOutputDeliveryQueue]
    var terminalScrollQueueTokensBySurfaceID: [String: UUID]
    var terminalScrollQueuesBySurfaceID: [String: TerminalScrollDeliveryQueue]
    var terminalScrollbackPrefetchStatesBySurfaceID: [String: TerminalScrollbackPrefetchState]
    /// Per-surface continuations for the Mac-pushed live font-size signal. A
    /// mounted surface obtains ``terminalLiveFontStream(surfaceID:)`` and applies
    /// each yielded point size; the Mac emits `terminal.set_font` to drive a live
    /// zoom (the grid reflows automatically). Mirrors
    /// ``terminalByteContinuationsBySurfaceID`` so the font signal rides the same
    /// per-surface fan-out shape as render-grid output.
    private var terminalLiveFontContinuationsBySurfaceID: [String: AsyncStream<Float32>.Continuation]
    /// Per-surface identity token for the live-font continuation above. A
    /// same-surface remount replaces the continuation (and this token) before the
    /// old cancelled stream's termination cleanup runs; the cleanup only tears
    /// down when its own token is still current, so it never deletes the new
    /// stream's continuation.
    private var terminalLiveFontTokensBySurfaceID: [String: UUID]
    private var rawTerminalInputBuffer: MobileTerminalInputSendBuffer
    private var pairingAttemptID: UUID

    /// High-level shell phase derived from sign-in and connection state.
    public var phase: MobileShellPhase {
        if !isSignedIn {
            return .signIn
        }
        if connectionState != .connected {
            return .pairing
        }
        return .workspaces
    }

    /// Workspace currently selected in the foreground shell, falling back to the first visible workspace.
    public var selectedWorkspace: MobileWorkspacePreview? {
        guard let selectedWorkspaceID else {
            return workspaces.first
        }
        return workspaces.first { $0.id == selectedWorkspaceID } ?? workspaces.first
    }

    var explicitlySelectedWorkspace: MobileWorkspacePreview? {
        guard let selectedWorkspaceID else { return nil }
        return workspaces.first { $0.id == selectedWorkspaceID }
    }

    /// Resolve a UI row id back to the Mac-local workspace id expected by RPC.
    ///
    /// Multi-Mac aggregation scopes row ids by Mac to avoid collisions, while
    /// the Mac host still expects its original local workspace id.
    func remoteWorkspaceID(for id: MobileWorkspacePreview.ID) -> MobileWorkspacePreview.ID {
        workspaces.first { $0.id == id }?.rpcWorkspaceID ?? id
    }

    /// Resolve a Mac-local workspace id to the current UI row id.
    func rowWorkspaceID(
        forRemoteWorkspaceID remoteID: MobileWorkspacePreview.ID,
        macDeviceID: String?
    ) -> MobileWorkspacePreview.ID? {
        workspaces.first { workspaceMatchesRemoteID($0, remoteID: remoteID, macDeviceID: macDeviceID) }?.id
    }

    private func workspaceMatchesRemoteID(
        _ workspace: MobileWorkspacePreview,
        remoteID: MobileWorkspacePreview.ID,
        macDeviceID: String?
    ) -> Bool {
        guard workspace.rpcWorkspaceID == remoteID else { return false }
        guard let macDeviceID, !macDeviceID.isEmpty else { return true }
        return workspace.macDeviceID == macDeviceID
    }

    private func remoteWorkspaceID(containingTerminalID terminalID: String) -> MobileWorkspacePreview.ID? {
        workspaces.first { workspace in
            workspace.terminals.contains(where: { $0.id.rawValue == terminalID })
        }?.rpcWorkspaceID
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

    /// Create a mobile shell store with injectable runtime services for app
    /// composition, previews, and package tests.
    public init(
        runtime: (any MobileSyncRuntime)? = nil,
        isSignedIn: Bool = false,
        connectionState: MobileConnectionState = .disconnected,
        connectedHostName: String = "",
        pairingCode: String = "",
        workspaces: [MobileWorkspacePreview] = [],
        pairedMacStore: (any MobilePairedMacStoring)? = nil,
        pairedMacRestoreBoundary: PairedMacRestoreBoundary? = nil,
        deviceRegistry: (any DeviceRegistryRefreshing)? = nil,
        presence: (any PresenceSubscribing)? = nil,
        clientIDRepository: MobileClientIDRepository = MobileClientIDRepository(defaults: .standard),
        identityProvider: (any MobileIdentityProviding)? = nil,
        teamIDProvider: @escaping @Sendable () async -> String? = { nil },
        reachability: any ReachabilityProviding = ReachabilityService(),
        routePinger: any CmxRoutePinging = CmxNetworkRoutePinger(),
        deliveredNotificationClearer: any DeliveredNotificationClearing = SystemDeliveredNotificationClearer(),
        pendingDismissQueue: PendingNotificationDismissQueue = PendingNotificationDismissQueue(),
        pairingHintDefaults: UserDefaults = .standard,
        multiMacAggregationDefaults: UserDefaults = .standard,
        forgottenMacStore: any PairedMacForgottenStoring = InMemoryPairedMacForgottenStore(),
        analytics: any AnalyticsEmitting = NoopAnalytics(),
        diagnosticLog: DiagnosticLog? = nil,
        feedbackEmailSubmitter: (any MobileFeedbackEmailSubmitting)? = nil,
        feedbackStampProvider: @escaping @MainActor () -> MobileFeedbackStamp = { MobileShellComposite.emptyFeedbackStamp },
        draftStore: (any TerminalDraftStoring)? = nil,
        groupCollapseStore: MobileWorkspaceGroupCollapseStore = MobileWorkspaceGroupCollapseStore()
    ) {
        self.runtime = runtime
        self.draftStore = draftStore
        self.groupCollapseStore = groupCollapseStore
        self.pairedMacStore = pairedMacStore
        self.pairedMacRestoreBoundary = pairedMacRestoreBoundary
        self.deviceRegistry = deviceRegistry
        self.presence = presence
        self.identityProvider = identityProvider
        self.teamIDProvider = teamIDProvider
        self.reachability = reachability
        self.routePinger = routePinger
        self.deliveredNotificationClearer = deliveredNotificationClearer
        self.pendingDismissQueue = pendingDismissQueue
        self.pairingHintDefaults = pairingHintDefaults
        self.multiMacAggregationDefaults = multiMacAggregationDefaults
        self.forgottenMacStore = forgottenMacStore
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
        // Seed the per-Mac source of truth from the injected workspaces (preview /
        // tests) so the derived list stays consistent; mirror it into the derived
        // cache directly since `didSet` does not fire during init.
        self.workspacesByMac = workspaces.isEmpty
            ? [:]
            : [Self.foregroundAnonymousKey: MacWorkspaceState(
                macDeviceID: Self.foregroundAnonymousKey, workspaces: workspaces)]
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
        self.chatEventSourceGeneration = UUID()
        self.reportedViewportSizesByTerminalKey = [:]
        self.deliveredTerminalByteEndSeqBySurfaceID = [:]
        self.pendingTerminalByteEndSeqBySurfaceID = [:]
        self.terminalActiveScreenBySurfaceID = [:]
        self.terminalReplaySurfaceIDsInFlight = []
        self.terminalOutputTransport = .rawBytes
        self.terminalByteContinuationsBySurfaceID = [:]
        self.terminalOutputStreamTokensBySurfaceID = [:]
        self.terminalOutputQueuesBySurfaceID = [:]
        self.terminalScrollQueueTokensBySurfaceID = [:]
        self.terminalScrollQueuesBySurfaceID = [:]
        self.terminalScrollbackPrefetchStatesBySurfaceID = [:]
        self.terminalLiveFontContinuationsBySurfaceID = [:]
        self.terminalLiveFontTokensBySurfaceID = [:]
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
        teardownSecondaryMacSubscriptions()
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
        chatSessionSnapshotsByWorkspaceID = [:]
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
        // Drop every account's staged photo bytes for the same reason as the
        // text drafts above: the pending attachments are this user's unsent
        // content, and a reused terminal id under the next account must never
        // surface the previous user's selected photos.
        pendingAttachmentsByTerminalID = [:]
        // Bump the session token so a photo load+encode already in flight (started
        // under this account) is dropped at its store-mutation re-check instead of
        // re-staging this user's bytes after the wipe above.
        signInGeneration &+= 1
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
        storedPairedMacs = []
        pairedMacAliasIDsByRepresentativeID = [:]
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
        // Tear down secondary-Mac aggregation at the account boundary: cancel any
        // in-flight aggregation pass and every live secondary subscription so the
        // previous user's Macs/workspaces cannot be re-seeded into the next
        // account after the reset below.
        teardownSecondaryMacSubscriptions()
        // Cancel any in-flight paired-Mac restore so a backup fetch suspended
        // across this sign-out cannot resume — possibly authorized with the next
        // account's live token — and write rows for the previous account. The
        // local store is intentionally retained (scoped per user) for a
        // same-account re-sign-in restore. Invalidate the shared boundary
        // synchronously first; the actor cleanup below is still fire-and-forget
        // because signOut is sync.
        pairedMacRestoreBoundary?.invalidate()
        if let refresher = pairedMacStore as? any PairedMacBackupRefreshing {
            Task { await refresher.cancelInFlightRestores() }
        }
        rawTerminalInputBuffer.clear()
        reportedViewportSizesByTerminalKey = [:]
        // Reset foreground identity to anonymous BEFORE seeding the anonymous
        // preview entry below: otherwise `foregroundMacKey` stays the old real Mac
        // id, the seeded entry lands under the anonymous key, and the next
        // `connect()` captures the stale real id as `previousForegroundKey` — so
        // `dropStalePreviousForeground` drops the wrong key and the preview rows
        // survive alongside the newly-connected Mac. Also drop the foreground
        // connection-pool entry so a stale per-Mac connection can't be reused.
        foregroundMacDeviceID = nil
        connections = [:]
        // Local preview / disconnected placeholder: seed the foreground (anonymous)
        // entry as the source of truth; `workspaces`/`workspaceGroups` derive from
        // it. Group sections are account-scoped like `pairedMacs`/`registryDevices`
        // above: the placeholder workspaces are ungrouped, and the previous
        // account's group names must not survive into the next session.
        workspacesByMac = [Self.foregroundAnonymousKey: MacWorkspaceState(
            macDeviceID: Self.foregroundAnonymousKey,
            workspaces: PreviewMobileHost.workspaces,
            groups: []
        )]
        selectedWorkspaceID = workspaces.first?.id
        selectedTerminalID = workspaces.first?.terminals.first?.id
        // Selection resets above are done; allow draft saving again so a
        // subsequent sign-in restores drafts normally.
        isLoadingDraft = false
    }

    /// Resume foreground-only refresh loops after the app becomes active.
    public func resumeForegroundRefresh() {
        startObservingNetworkPathChanges()
        // Covers stores constructed already-signed-in (no isSignedIn edge) and
        // restarts a subscription torn down while backgrounded.
        evaluatePresenceSubscription()
        resyncTerminalOutput(reason: "foreground", restartEventStream: true)
        // The foreground Mac's workspace list updates live over the sync stream,
        // but the other Macs are a read-only snapshot. Re-aggregate them on
        // foreground so workspaces created on another Mac while backgrounded
        // appear without a manual pull-to-refresh.
        if multiMacAggregationEnabled, connectionState == .connected {
            self.scheduleSecondaryAggregation()
        }
    }

    /// React to a Stack team switch. The team-scoped services (presence, device
    /// registry, paired-Mac backup/restore, secondary aggregation) all read the
    /// selected team LIVE, so the data layer is already correct on the next call.
    /// This only invalidates the in-process state built under the OLD team and lets
    /// it rebuild LAZILY for the new one — and deliberately does NOT touch the live
    /// foreground terminal session: `remoteClient`, `foregroundMacDeviceID`, and the
    /// foreground Mac's `workspacesByMac` entry are left intact, so switching teams
    /// never drops the terminal the user is in (the chosen "keep session, re-scope
    /// lists" behavior).
    public func currentTeamDidChange() {
        secondaryAggregationScopeGeneration &+= 1
        // Presence: cancel + re-subscribe so the online dots reflect the new team
        // (the subscribe reads the team live). Cheap live socket; the only eager bit.
        presenceTask?.cancel()
        presenceTask = nil
        presenceMap = PresenceMap()
        evaluatePresenceSubscription()
        // Secondary aggregation: tear down the OTHER Macs' read-only subscriptions
        // and drop their aggregated rows so the old team's Macs stop showing. Keep
        // ONLY the foreground entry. Do NOT re-aggregate here — that rebuilds lazily
        // on the next foreground / Computers `.task` / pull-to-refresh.
        teardownSecondaryMacSubscriptions()
        let foregroundKey = foregroundMacKey
        workspacesByMac = workspacesByMac.filter { $0.key == foregroundKey }
        // Restore memo: invalidate so the next read re-restores for the new
        // (account, team) scope, and a suspended old-team restore can't resume.
        // Invalidate the shared boundary synchronously first; actor cleanup is
        // fire-and-forget (this method is sync) and does not wipe the local store.
        pairedMacRestoreBoundary?.invalidate()
        if let refresher = pairedMacStore as? any PairedMacBackupRefreshing {
            Task { await refresher.cancelInFlightRestores() }
        }
        // Lazy display: clear the stale old-team lists; the next loadPairedMacs() /
        // loadRegistryDevices() (DeviceTreeView `.task`) repopulate scoped to the
        // new team. The foreground workspace list (derived from the kept entry) is
        // unaffected.
        storedPairedMacs = []
        pairedMacAliasIDsByRepresentativeID = [:]
        pairedMacs = []
        forgottenMacDeviceIDsByScope = [:]
        registryDevices = []
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
            let remoteWorkspaceID = remoteWorkspaceID(for: workspaceID)
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.terminal.mouse",
                params: [
                    "workspace_id": remoteWorkspaceID.rawValue,
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
        if CmxPairingURLScheme.hasPairingScheme(trimmedCode) {
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

    /// Connect using the current pairing input, accepting either a code or pairing URL.
    public func connectPairingInput() async {
        let trimmedCode = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            return
        }
        if CmxPairingURLScheme.hasPairingScheme(trimmedCode) {
            await connectPairingURL(trimmedCode)
            return
        }
        connectPreviewHost()
    }

    /// Connect to a manually-entered Mac host and optionally associate the
    /// resulting session with an existing paired-Mac device id.
    public func connectManualHost(
        name: String, host: String, port: Int, pairedMacDeviceID: String? = nil
    ) async {
        await connectManualHost(
            name: name,
            host: host,
            port: port,
            pairedMacDeviceID: pairedMacDeviceID,
            recordsPairingAttempt: true
        )
    }

    private func connectStoredMacHost(
        name: String,
        host: String,
        port: Int,
        pairedMacDeviceID: String
    ) async {
        await connectManualHost(
            name: name,
            host: host,
            port: port,
            pairedMacDeviceID: pairedMacDeviceID,
            recordsPairingAttempt: false
        )
    }

    /// - Parameter pairedMacDeviceID: the REAL paired-Mac device id when the caller
    ///   knows it (switch/reconnect/device-row paths). A manual host whose Mac lacks
    ///   `mobile.attach_ticket.create` connects via a synthetic `manual-…` ticket;
    ///   passing the real id keys the foreground aggregate state under it instead of
    ///   the synthetic id. `nil` for a genuinely manual/unknown host.
    private func connectManualHost(
        name: String,
        host: String,
        port: Int,
        pairedMacDeviceID: String? = nil,
        recordsPairingAttempt: Bool
    ) async {
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
        activeRoute = directRoute
        let attemptID = recordsPairingAttempt ? beginPairingAttempt(method: "manual") : beginPairingValidationAttempt()
        // Fast offline preflight: fail immediately instead of stacking
        // per-route timeouts into the opaque ~60s blob.
        let manualRoutes = directRoute.map { [$0] } ?? []
        guard await failPairingIfOffline(attemptID: attemptID, phase: "preflight", routes: manualRoutes) == .proceed else { return }
        do {
            let ticket = try await manualHostTicket(
                name: trimmedName,
                host: normalizedHost,
                port: port,
                attemptStartedAt: pairingAttemptStartedAt
            )
            guard isCurrentPairingAttempt(attemptID) else { return }
            let noThrowFailure = try await connect(
                ticket: ticket, allowsStackAuthFallback: true, pairedMacDeviceID: pairedMacDeviceID)
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
        guard isSignedIn,
              let scope = await currentScopeSnapshot(userID: stackUserID) else {
            finishStoredMacReconnectAttempt(generation: generation)
            return false
        }
        // Pull the authoritative per-user backup first so saved-Mac routes are
        // current before we dial: a Mac that relaunched on a new port republishes
        // to the backup, and LWW by lastSeenAt keeps any live local edit. Without
        // this a stale port makes the auto-connect fail and the app falls back to
        // the Mac picker, the screen we want to avoid showing.
        if let refresher = pairedMacStore as? any PairedMacBackupRefreshing {
            await refresher.refreshFromBackup(stackUserID: scope.userID)
        }
        guard await isScopeCurrent(scope) else { finishStoredMacReconnectAttempt(generation: generation); return false }
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        func reachableRoute(_ mac: MobilePairedMac) -> (String, Int)? {
            Self.firstReconnectHostPortRoute(
                mac.routes,
                supportedKinds: supportedKinds,
                preferNonLoopback: Self.prefersNonLoopbackRoutes
            )
        }
        let loadedActiveMac: MobilePairedMac?
        let loadedMacs: [MobilePairedMac]
        do {
            loadedActiveMac = try await pairedMacStore.activeMac(stackUserID: scope.userID, teamID: scope.teamID)
            loadedMacs = try await pairedMacStore.loadAll(stackUserID: scope.userID, teamID: scope.teamID)
        } catch {
            mobileShellLog.error("paired mac store read failed: \(String(describing: error), privacy: .public)")
            // A read failure means "couldn't determine," not "no mac": keep the
            // hint so a transient SQLite error doesn't erase a returning user's
            // paired state.
            finishStoredMacReconnectAttempt(generation: generation)
            return false
        }
        guard await isScopeCurrent(scope) else { finishStoredMacReconnectAttempt(generation: generation); return false }
        let forgottenIDs = await forgottenMacDeviceIDs(scope: scope)
        guard await isScopeCurrent(scope) else {
            finishStoredMacReconnectAttempt(generation: generation)
            return false
        }
        let activeMac = loadedActiveMac.flatMap { forgottenIDs.contains($0.macDeviceID) ? nil : $0 }
        let allMacs = loadedMacs.filter { !forgottenIDs.contains($0.macDeviceID) }
        // Auto-connect target: the explicitly active Mac when it is reachable,
        // otherwise the FIRST saved Mac with a usable route. Picking the first
        // reachable Mac instead of bailing when nothing is marked active is what
        // lets the home come up connected without the user choosing a Mac; the
        // other Macs are then aggregated read-only into one integrated list.
        // Candidate Macs in priority order: the active Mac first (when it has a
        // usable route), then every OTHER saved Mac with a usable route. A
        // down/unreachable Mac has a route but fails the connect, so we fall
        // through to the next candidate instead of stranding the user on "Mac
        // offline" just because their active Mac happens to be off.
        var candidates: [MobilePairedMac] = []
        if let activeMac, reachableRoute(activeMac) != nil {
            candidates.append(activeMac)
        }
        candidates.append(contentsOf: allMacs.filter { mac in
            mac.macDeviceID != activeMac?.macDeviceID && reachableRoute(mac) != nil
        })
        guard !candidates.isEmpty else {
            // No saved Mac has a usable route right now (none paired, or all
            // offline). Clear the hint only when there are truly no saved Macs, so
            // the add-device sheet comes up cleanly; otherwise keep it so a Retry
            // or network change can reconnect once a Mac comes back.
            setHasKnownPairedMac(!allMacs.isEmpty, generation: generation)
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
        // that whole time. After the deadline, resolve the gate so the list shows
        // quickly; the connect loop keeps trying, so a later success still flips
        // connectionState to .connected and shows the workspaces.
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
        // Try each candidate until one connects, so a single offline Mac never
        // blocks the others.
        for mac in candidates {
            guard generation == storedMacReconnectGeneration,
                  await isScopeCurrent(scope),
                  let (host, port) = reachableRoute(mac) else { break }
            let latestForgottenIDs = await forgottenMacDeviceIDs(scope: scope)
            guard generation == storedMacReconnectGeneration, await isScopeCurrent(scope), !latestForgottenIDs.contains(mac.macDeviceID) else { break }
            // Best-effort registry refresh for this Mac in the background.
            refreshRoutesFromRegistry(for: mac, scope: scope)
            await connectStoredMacHost(
                name: mac.displayName ?? host, host: host, port: port,
                pairedMacDeviceID: mac.macDeviceID)
            if connectionState == .connected { break }
        }
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
    private func refreshRoutesFromRegistry(for mac: MobilePairedMac, scope: MobileShellScopeSnapshot) {
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
            // resurrect or reactivate a pairing the user removed. Pass the
            // captured account/team scope through every store call so a team
            // switch cannot make this old-team refresh write into the new team.
            guard await self.isScopeCurrent(scope) else { return }
            guard await !self.isForgottenMacDeviceID(macDeviceID, scope: scope) else { return }
            let activeMacID: String?
            do {
                activeMacID = try await pairedMacStore.activeMac(
                    stackUserID: scope.userID,
                    teamID: scope.teamID
                )?.macDeviceID
            } catch {
                mobileShellLog.debug("registry refresh active-mac recheck failed: \(String(describing: error), privacy: .public)")
                return
            }
            guard await self.isScopeCurrent(scope) else { return }
            guard await !self.isForgottenMacDeviceID(macDeviceID, scope: scope) else { return }
            guard DeviceRegistryService.shouldApplyRegistryRefresh(
                isSignedIn: self.isSignedIn,
                capturedUserID: scope.userID,
                currentUserID: self.identityProvider?.currentUserID ?? scope.userID,
                activeMacID: activeMacID,
                targetMacID: macDeviceID
            ) else { return }
            do {
                try await pairedMacStore.upsert(
                    macDeviceID: macDeviceID,
                    displayName: displayName,
                    routes: updated,
                    markActive: true,
                    stackUserID: scope.userID,
                    teamID: scope.teamID,
                    now: Date()
                )
            } catch {
                mobileShellLog.debug("registry route refresh upsert failed: \(String(describing: error), privacy: .public)")
                return
            }
            if await self.isForgottenMacDeviceID(macDeviceID, scope: scope) {
                do {
                    try await pairedMacStore.remove(
                        macDeviceID: macDeviceID,
                        stackUserID: scope.userID,
                        teamID: scope.teamID
                    )
                } catch {
                    mobileShellLog.debug("registry route refresh stale-row cleanup failed: \(String(describing: error), privacy: .public)")
                }
                return
            }
            if await self.isScopeCurrent(scope) {
                await self.loadPairedMacs()
            }
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

    /// Full store rows for identity-sensitive paths; ``pairedMacs`` is display-coalesced.
    private var storedPairedMacs: [MobilePairedMac] = []
    /// Visible representative id to all stored ids for that logical paired Mac.
    public private(set) var pairedMacAliasIDsByRepresentativeID: [String: [String]] = [:]
    /// Same-session delete tombstones keyed by signed-in account/team scope.
    ///
    /// The durable backup layer already preserves deletes across relaunch and
    /// failed cloud tombstone uploads. This in-memory set covers the remaining
    /// race: a presence or registry refresh task that started before `forgetMac`
    /// can write the removed row back into the local store after the remove
    /// completes. Filtering the current scope keeps that late write hidden until
    /// the user explicitly pairs/connects that Mac again.
    @ObservationIgnored var forgottenMacDeviceIDsByScope: [String: Set<String>] = [:]

    var pairedMacsForIdentityMatching: [MobilePairedMac] {
        storedPairedMacs.isEmpty ? pairedMacs : storedPairedMacs
    }
    // MARK: - Device registry tree

    /// The team's registered devices and their cmux app instances (tags), for the
    /// device tree (device → tags → workspaces). Fetched from the team-scoped
    /// device registry via ``loadRegistryDevices()``. Empty until the first load,
    /// when the registry is unreachable, or after sign-out. Best-effort: a
    /// registry outage leaves this empty and the UI falls back to the locally
    /// known paired Macs, so the tree degrades to the same hosts the switcher
    /// shows rather than going blank.
    public internal(set) var registryDevices: [RegistryDevice] = []

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
        guard let deviceRegistry,
              let scope = await currentScopeSnapshot() else {
            registryDevices = []
            return
        }
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
            if await isScopeCurrent(scope) {
                registryDevices = []
            }
            return
        case .transientFailure:
            // Network blip / 5xx / malformed body: keep what we have rather than
            // blanking a populated tree on a transient failure.
            return
        }
        // The await above suspended the main actor; discard the result unless we
        // are still in the same signed-in account/team scope, so a slow load can
        // never repopulate another scope's devices after sign-out, account switch,
        // or same-account team switch.
        guard await isScopeCurrent(scope) else { return }
        let connectedID = connectedMacDeviceID
        let forgottenIDs = await forgottenMacDeviceIDs(scope: scope)
        guard await isScopeCurrent(scope) else { return }
        registryDevices = loaded.filter { !forgottenIDs.contains($0.deviceId) }.sorted { lhs, rhs in
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
                    guard let scope = await self?.currentScopeSnapshot() else { return }
                    let stream = try await presence.subscribe()
                    for try await update in stream {
                        guard let self,
                              !Task.isCancelled,
                              await self.isScopeCurrent(scope) else { return }
                        backoff = .seconds(1)
                        self.applyPresenceUpdate(update, scope: scope)
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

    func applyPresenceUpdate(_ update: PresenceUpdate, scope: MobileShellScopeSnapshot) {
        presenceMap.apply(update)
        switch update {
        case .routes(let instance), .online(let instance):
            // Both events can carry fresh attach routes (online = a host that
            // re-announced after moving networks while the phone was watching).
            syncPushedRoutes(from: instance, scope: scope)
        case .snapshot(let snapshot):
            // The snapshot is the reconcile-on-(re)subscribe path: a port that
            // changed while the phone was offline lands here. One batch (not
            // one task per instance) so a multi-tag Mac syncs routes in
            // deterministic order and kicks at most one reconnect.
            syncPushedRoutes(from: snapshot.devices.flatMap { device in
                device.instances.filter(\.online)
            }, scope: scope)
        case .offline, .seen:
            break
        }
    }

    func waitForPushedRouteSyncForTesting() async {
        await pushedRouteSyncTask?.value
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
    private func syncPushedRoutes(from instance: PresenceInstance, scope: MobileShellScopeSnapshot) {
        syncPushedRoutes(from: [instance], scope: scope)
    }

    /// Batch form: one sequential task for the whole delivery (a snapshot can
    /// carry several online instances, including multiple tags on one Mac),
    /// so route upserts apply in deterministic order and the reconnect kick
    /// fires at most once per delivery instead of once per instance.
    private func syncPushedRoutes(from instances: [PresenceInstance], scope: MobileShellScopeSnapshot) {
        let candidates = instances.filter { $0.platform.lowercased() != "ios" }
        guard !candidates.isEmpty else { return }
        // Every await below suspends the main actor, so keep carrying the
        // account/team scope captured for the subscription that delivered this
        // frame and re-check it before each route mutation. A stale frame from a
        // previous account or team must never write routes into, or kick
        // reconnects for, the next scope.
        // Serialized on the paired-Mac write chain: a (re)subscribe delivers
        // a snapshot immediately followed by online/routes events for the
        // same device, and two concurrent deliveries would race their
        // pairedMacStore upserts and could each kick a reconnect. The chain
        // appends synchronously on the main actor, so deliveries execute
        // strictly in arrival order.
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performSerializedPairedMacWrite(ifStillCurrent: nil) {
                [weak self] in
                guard let self else { return }
                guard await self.isScopeCurrent(scope) else { return }
                if self.pairedMacsForIdentityMatching.isEmpty {
                    // A presence frame can land before the first paired-Mac
                    // load (snapshot arrives fast on launch); resolve the
                    // pairing list before deciding these devices are unknown.
                    await self.loadPairedMacs()
                }
                guard await self.isScopeCurrent(scope) else { return }
                var onlineDeviceIds: Set<String> = []
                for instance in candidates {
                    guard await self.isScopeCurrent(scope) else { return }
                    if instance.online { onlineDeviceIds.insert(instance.deviceId) }
                    await self.applyPushedRoutes(from: instance, scope: scope)
                }
                guard await self.isScopeCurrent(scope) else { return }
                // The Mac this phone wants is online and we are not
                // connected: reconnect now instead of waiting for the user to
                // pull Retry. Unambiguous pushes were persisted above, so the
                // reconnect dials fresh routes; under the multi-instance
                // ambiguity guard the stored last-known-good routes are
                // deliberately kept and the reconnect uses those, the same
                // outcome a manual Retry would have.
                let knownMacs = self.pairedMacsForIdentityMatching
                if self.connectionState != .connected,
                   let activeMacID = self.pairedMacs.first(where: { $0.isActive })?.macDeviceID,
                   !onlineDeviceIds.isDisjoint(with: Self.macDeviceIDsForLogicalPairedMac(
                        activeMacID,
                        in: knownMacs,
                        supportedKinds: self.runtime?.supportedRouteKinds ?? [],
                        preferNonLoopback: Self.prefersNonLoopbackRoutes
                   )) {
                    self.recoverMobileConnection(trigger: .presencePush)
                }
            }
        }
        pushedRouteSyncTask = task
    }

    /// Per-instance store/registry write-through for the batch sync above.
    private func applyPushedRoutes(from instance: PresenceInstance, scope: MobileShellScopeSnapshot) async {
        // `nil` means the host did not announce routes on this record
        // ("unchanged" on the wire); an explicit `[]` is a live clear.
        guard let routes = instance.routes else { return }
        guard await isScopeCurrent(scope) else { return }
        let deviceId = instance.deviceId
        guard await !isForgottenMacDeviceID(deviceId, scope: scope) else { return }
        let knownMacs = pairedMacsForIdentityMatching
        guard knownMacs.contains(where: { $0.macDeviceID == deviceId }) else {
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
        // The paired-Mac store keeps last-known-good reconnect routes. The store
        // is device-level (no tag), so substitution must stay unambiguous and
        // scoped to the stored id that emitted the presence frame.
        guard !routes.isEmpty,
              let sole = presenceMap.soleRouteAdvertisingInstance(deviceId: deviceId),
              sole.tag == instance.tag,
              let mac = knownMacs.first(where: { $0.macDeviceID == deviceId }),
              let updated = DeviceRegistryService.selectReconnectRoutes(
                local: mac.routes,
                registry: routes
              ),
              let pairedMacStore,
              await isScopeCurrent(scope) else { return }
        do {
            try await pairedMacStore.upsert(
                macDeviceID: mac.macDeviceID,
                displayName: mac.displayName,
                routes: updated,
                markActive: mac.isActive,
                stackUserID: scope.userID,
                teamID: scope.teamID,
                now: Date()
            )
            guard await isScopeCurrent(scope) else { return }
            if await removeStoredPairedMacIfForgotten(mac.macDeviceID, scope: scope) { return }
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
            supportedKinds: supportedKinds,
            preferNonLoopback: Self.prefersNonLoopbackRoutes
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
        let scope = await currentScopeSnapshot()
        await connectManualHost(
            name: device.displayName ?? host, host: host, port: port,
            pairedMacDeviceID: device.deviceId)
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
            if let scope {
                guard await isScopeCurrent(scope) else { return }
            }
            do {
                try await pairedMacStore.upsert(
                    macDeviceID: device.deviceId,
                    displayName: device.displayName,
                    routes: instance.routes,
                    markActive: true,
                    stackUserID: scope?.userID,
                    teamID: scope?.teamID,
                    now: Date()
                )
                await clearForgottenMacDeviceID(device.deviceId, scope: scope)
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
        guard let pairedMacStore,
              let scope = await currentScopeSnapshot() else {
            storedPairedMacs = []
            pairedMacAliasIDsByRepresentativeID = [:]
            pairedMacs = []
            return
        }
        let loaded: [MobilePairedMac]
        do {
            loaded = try await pairedMacStore.loadAll(stackUserID: scope.userID, teamID: scope.teamID)
        } catch {
            mobileShellLog.error("paired mac store loadAll failed: \(String(describing: error), privacy: .public)")
            return
        }
        // The await above suspended the main actor; a sign-out, user switch, or
        // same-account team switch may have run meanwhile. Discard unless the
        // captured account/team scope is still current.
        guard await isScopeCurrent(scope) else {
            return
        }
        let visibleLoaded = await visibleStoredPairedMacs(from: loaded, scope: scope)
        guard await isScopeCurrent(scope) else {
            return
        }
        storedPairedMacs = visibleLoaded
        let coalesced = Self.coalescePairedMacsByDialEndpoint(visibleLoaded, supportedKinds: runtime?.supportedRouteKinds ?? [], preferNonLoopback: Self.prefersNonLoopbackRoutes)
        pairedMacAliasIDsByRepresentativeID = coalesced.reduce(into: [String: [String]]()) { result, mac in
            result[mac.macDeviceID] = Self.macDeviceIDsForLogicalPairedMac(
                mac.macDeviceID,
                in: visibleLoaded,
                supportedKinds: runtime?.supportedRouteKinds ?? [],
                preferNonLoopback: Self.prefersNonLoopbackRoutes
            )
        }
        pairedMacs = visibleLoaded
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
    /// - Returns: `true` if the foreground connection now targets that Mac (or
    ///   already did), `false` if the switch could not connect — so callers like
    ///   `openWorkspace` can avoid selecting a workspace whose Mac is not live.
    /// Promote the live read-only secondary connection for `macID` to the
    /// foreground by REUSING its client — no re-dial. Returns `false` (so the
    /// caller re-dials) when no live secondary exists or it no longer responds.
    ///
    /// This is the fix for "Mac offline" on a reachable Mac: re-dialing the
    /// foreground (refreshFromBackup route re-derivation + offline preflight +
    /// `connect()` pairing-generation race) has several independent failure points,
    /// any of which strands the user even though a working client to that exact Mac
    /// already sits in `secondaryMacSubscriptions`. Reusing it makes that failure
    /// unrepresentable for an already-aggregated Mac.
    private func promoteSecondaryToForeground(_ macID: String) async -> Bool {
        guard runtime != nil, let sub = secondaryMacSubscriptions[macID] else { return false }
        // Probe the live client so we only promote a connection that responds NOW
        // (the read-only stream can have silently dropped); on failure, re-dial.
        guard let previews = await fetchSecondaryWorkspaces(on: sub.client, macDeviceID: macID),
              secondaryMacSubscriptions[macID] === sub else { return false }
        mobileShellLog.info("promote: reusing live secondary connection as foreground mac=\(macID, privacy: .public)")
        // Take a fresh connection generation so the foreground machinery (polling,
        // event listener, in-flight request guards) treats this client as current.
        let generation = UUID()
        connectionAttemptGeneration = generation
        connectionGeneration = generation
        cancelRemoteOperationTasks() // stop the OLD foreground's polling/tasks
        // Capture the OLD foreground key before the id flips so its now-stale
        // snapshot can be dropped from the aggregate after the swap.
        let previousForegroundKey = foregroundMacKey
        // Take ownership of the live client; do NOT disconnect it.
        secondaryMacSubscriptions[macID] = nil
        sub.detachKeepingClient()
        let displayName = workspacesByMac[macID]?.displayName
        activeTicket = sub.ticket
        activeRoute = sub.route
        connectedHostName = placeholderHostName(for: sub.ticket, firstRoute: sub.route)
        replaceRemoteClient(with: sub.client)
        foregroundMacDeviceID = macID
        supportedHostCapabilities = sub.supportedHostCapabilities
        workspacesByMac[macID] = MacWorkspaceState(
            macDeviceID: macID,
            displayName: displayName,
            workspaces: previews,
            status: .connected,
            actionCapabilities: sub.actionCapabilities
        )
        // The previous foreground's live client was just replaced; drop its stale
        // rows (re-added as a secondary by scheduleSecondaryAggregation below).
        dropStalePreviousForeground(previousForegroundKey)
        connectionState = .connected
        markMacConnectionHealthy()
        // Tear down the OLD foreground's terminal event listener before starting a
        // fresh one. `cancelRemoteOperationTasks()` above does NOT clear
        // `terminalEventListenerTask`/`terminalEventListenerID`, and
        // `startTerminalRefreshPolling()` no-ops while a listener task is still
        // installed — so without this the promoted client would never get its
        // terminal/workspace/notification push stream and output would stall until
        // some other path restarted it. The stop+start mirrors `restartEventStream`;
        // the old listener's `== listenerID` defer guard keeps its async teardown
        // from clobbering the new listener/watchdog.
        stopTerminalRefreshPolling()
        startTerminalRefreshPolling()
        syncSelectedTerminalForWorkspace()
        if let pairedMacStore {
            let scope = await currentScopeSnapshot()
            Task {
                try? await pairedMacStore.setActive(
                    macDeviceID: macID,
                    stackUserID: scope?.userID,
                    teamID: scope?.teamID
                )
            }
        }
        // Re-aggregate so the PREVIOUS foreground Mac comes back as a secondary.
        scheduleSecondaryAggregation()
        return true
    }

    /// Switch the foreground connection to another paired Mac.
    @discardableResult
    public func switchToMac(macDeviceID: String) async -> Bool {
        guard let pairedMacStore else { return false }
        // FAST PATH: if a live read-only connection to this Mac already exists,
        // promote it to the foreground (reuse the client) instead of re-dialing.
        if await promoteSecondaryToForeground(macDeviceID) { return true }
        // Refresh routes from the per-user backup so a Mac that relaunched on a
        // new port is reachable — the same freshness guarantee auto-connect and
        // aggregation use — then resolve the target from the STORE (authoritative).
        // The multi-Mac aggregation reads Macs straight from the store and can
        // surface a Mac (a freshly restored secondary) that the in-memory
        // `pairedMacs` cache has not loaded yet; gating on that cache would no-op
        // the open and strand the user on a workspace whose Mac never connected.
        if let refresher = pairedMacStore as? any PairedMacBackupRefreshing {
            await refresher.refreshFromBackup(stackUserID: identityProvider?.currentUserID)
        }
        let scope = await currentScopeSnapshot()
        let storeMacs = (try? await pairedMacStore.loadAll(
            stackUserID: scope?.userID ?? identityProvider?.currentUserID,
            teamID: scope?.teamID
        )) ?? []
        guard let refreshedTarget = storeMacs.first(where: { $0.macDeviceID == macDeviceID })
            ?? pairedMacs.first(where: { $0.macDeviceID == macDeviceID }) else { return false }
        // Already foreground on this exact Mac: skip the re-dial. Gate on the LIVE
        // foreground identity, not the persisted `isActive` flag — `isActive` is
        // stored preference state that can lag the real connection (e.g.
        // `promoteSecondaryToForeground` writes it via an unawaited Task, and it is
        // stale during reconnect/switch races). Trusting it could make `openWorkspace`
        // proceed without switching and route input/mutations to the wrong Mac.
        if foregroundMacDeviceID == macDeviceID, connectionState == .connected { return true }
        // The currently-active Mac to fall back to if the switch fails.
        let previousActive = storeMacs.first { $0.isActive && $0.macDeviceID != macDeviceID }
            ?? pairedMacs.first { $0.isActive && $0.macDeviceID != macDeviceID }
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        guard let (host, port) = Self.firstReconnectHostPortRoute(
            refreshedTarget.routes,
            supportedKinds: supportedKinds,
            preferNonLoopback: Self.prefersNonLoopbackRoutes
        ), let normalizedHost = MobileShellRouteAuthPolicy.normalizedManualHost(host) else {
            mobileShellLog.error("switchToMac: no reconnectable route mac=\(macDeviceID, privacy: .public)")
            return false
        }
        await connectManualHost(
            name: refreshedTarget.displayName ?? host, host: host, port: port,
            pairedMacDeviceID: macDeviceID)
        // The switch succeeded only if the live connection is to THIS Mac's route.
        // A different switch tapped while this connect was in flight supersedes it
        // via `beginPairingAttempt`, leaving `connectionState` `.connected` for the
        // other Mac; matching the live route prevents this superseded task from
        // persisting a stale active target or reporting a false success.
        let switched = connectionState == .connected
            && {
                if case let .hostPort(liveHost, livePort)? = activeRoute?.endpoint {
                    return liveHost == normalizedHost && livePort == port
                }
                return false
            }()
        if switched {
            do {
                try await pairedMacStore.setActive(
                    macDeviceID: macDeviceID,
                    stackUserID: scope?.userID,
                    teamID: scope?.teamID
                )
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
        return switched
    }

    func clearSavedMacHintAfterDeletingLastVisibleMacIfNeeded() {
        guard pairedMacs.isEmpty else { return }
        storedMacReconnectGeneration &+= 1
        hasKnownPairedMac = false
        isReconnectingStoredMac = false
        didFinishStoredMacReconnectAttempt = false
    }

    /// Whether route selection should avoid loopback routes. A loopback route
    /// (`.debugLoopback`, `127.0.0.1`) names the host it runs on, so on a
    /// physical device it can only ever reach the phone itself, never a remote
    /// Mac. On the simulator `127.0.0.1` IS the host Mac, so loopback is valid
    /// (and is how the dev/UI-test mock host attaches).
    static var prefersNonLoopbackRoutes: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    /// The first reachable host/port route to a Mac, in priority order.
    ///
    /// When `preferNonLoopback` is set (physical devices), a real route
    /// (`.tailscale` etc.) is always chosen over a `.debugLoopback` route even
    /// if the loopback route has a lower (more-preferred) priority, because a
    /// loopback route can never reach a remote Mac from a physical phone. A
    /// loopback route is used only when it is the sole supported route — the
    /// on-device XCUITest mock host, which serves a real listener on `127.0.0.1`
    /// inside the test runner. This is what lets a restored Mac (whose published
    /// routes include both `debug_loopback` and `tailscale`) actually connect
    /// over Tailscale instead of dialing the phone's own loopback and failing.
    static func firstReconnectHostPortRoute(
        _ routes: [CmxAttachRoute],
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool = false
    ) -> (String, Int)? {
        let supportedKinds = Set(supportedKinds)
        let ordered = routes.sorted(by: Self.routeSortsBefore)
        func firstHostPort(where predicate: (CmxAttachRoute) -> Bool) -> (String, Int)? {
            for route in ordered {
                if !supportedKinds.isEmpty, !supportedKinds.contains(route.kind) {
                    continue
                }
                guard predicate(route), case let .hostPort(host, port) = route.endpoint else {
                    continue
                }
                return (host, port)
            }
            return nil
        }
        if preferNonLoopback {
            // Among non-loopback routes, prefer one whose host is a numeric IP: a
            // raw tailscale/LAN IP is dialable without DNS, whereas a MagicDNS
            // hostname (e.g. "<node>.<tailnet>.ts.net") depends on the client
            // having tailscale DNS active and resolving it. On devices where
            // MagicDNS isn't resolving, dialing the hostname times out and the Mac
            // silently drops out of the list, even though its IP route is fine.
            if let ip = firstHostPort(where: { route in
                guard route.kind != .debugLoopback,
                      case let .hostPort(host, _) = route.endpoint else { return false }
                return Self.isIPLiteralHost(host)
            }) {
                return ip
            }
            if let real = firstHostPort(where: { $0.kind != .debugLoopback }) {
                return real
            }
        }
        return firstHostPort(where: { _ in true })
    }

    /// Whether `host` is a numeric IP literal (IPv4 or IPv6) rather than a name
    /// that needs DNS resolution. Used to prefer directly-dialable IP routes over
    /// MagicDNS hostnames, which fail to resolve on some clients.
    static func isIPLiteralHost(_ host: String) -> Bool {
        if host.contains(":") { return true } // IPv6 literal
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { part in
            guard let value = Int(part), (0...255).contains(value), !part.isEmpty else { return false }
            return String(value) == part // reject leading zeros / non-canonical
        }
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
        let scope = await currentScopeSnapshot(userID: stackUserID)
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
            if let scope {
                guard await self.isScopeCurrent(scope) else { return }
            }
            var displayName = ticketDisplayName
            if displayName == nil {
                let knownMacs = (try? await pairedMacStore.loadAll(
                    stackUserID: nil,
                    teamID: scope?.teamID
                )) ?? []
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
                    stackUserID: stackUserID,
                    teamID: scope?.teamID,
                    now: Date()
                )
                await self.clearForgottenMacDeviceID(ticket.macDeviceID, scope: scope)
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
            // Move the foreground aggregate key from the anonymous key to the real
            // id so the Computers screen recognizes this Mac as connected and
            // secondary aggregation excludes it (no duplicate connection to self).
            adoptForegroundMacIdentity(reportedID)
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
        let scope = await currentScopeSnapshot(userID: stackUserID)
        await performSerializedPairedMacWrite(ifStillCurrent: ifStillCurrent) {
            if let scope {
                guard await self.isScopeCurrent(scope) else { return }
            }
            do {
                try await pairedMacStore.upsert(
                    macDeviceID: ticket.macDeviceID,
                    displayName: name,
                    routes: ticket.routes,
                    markActive: true,
                    stackUserID: stackUserID,
                    teamID: scope?.teamID,
                    now: Date()
                )
                await self.clearForgottenMacDeviceID(ticket.macDeviceID, scope: scope)
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

    static func manualHostRoute(host: String, port: Int) throws -> CmxAttachRoute {
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
            } else if case MobileSyncPairingPayloadError.unrecognizedURLVersion = error {
                // A real cmux QR whose grammar version this build predates: the
                // fix is updating the app, not re-scanning, so say so instead of
                // the generic "not a valid code" copy.
                applyPairingValidationFailure(.unrecognizedVersion)
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
    func disconnectLiveConnection(preservingOtherMacWorkspaceState: Bool = false) {
        suppressNextConnectionOutageEdge = true
        invalidatePairingAttempt()
        clearPairingError()
        connectionRequiresReauth = false
        connectionState = .disconnected
        macConnectionStatus = .unavailable
        clearRemoteConnectionContext(preservingOtherMacWorkspaceState: preservingOtherMacWorkspaceState)
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
                    let scope = await self.currentScopeSnapshot()
                    try await pairedMacStore.remove(
                        macDeviceID: macID,
                        stackUserID: scope?.userID,
                        teamID: scope?.teamID
                    )
                } catch {
                    mobileShellLog.error("forgetActiveMac removal failed: \(String(describing: error), privacy: .private)")
                }
            }
        }
    }

    /// Build a persistent read-only client to one OTHER Mac (route + manual
    /// ticket), or nil if it has no reachable route / the ticket fails. The caller
    /// owns disconnecting it. Routes are loopback-deprioritized on device. Never
    /// touches the foreground connection.
    private func makeSecondaryClient(for mac: MobilePairedMac) async -> SecondaryClientHandle? {
        guard let runtime else { return nil }
        let supportedKinds = runtime.supportedRouteKinds
        guard let (host, port) = Self.firstReconnectHostPortRoute(
            mac.routes,
            supportedKinds: supportedKinds,
            preferNonLoopback: Self.prefersNonLoopbackRoutes
        ) else {
            return nil
        }
        let ticket: CmxAttachTicket
        do {
            ticket = try await manualHostTicket(
                name: mac.displayName ?? host,
                host: host,
                port: port,
                attemptStartedAt: nil
            )
        } catch {
            mobileShellLog.warning(
                "secondary client: ticket failed mac=\(mac.macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return nil
        }
        let supportedRoutes = Self.supportedRoutes(for: ticket, supportedKinds: supportedKinds)
        // Dial the route we PROVED reachable above (the non-loopback host/port the
        // ticket was built from), NOT `supportedRoutes.first`: on a physical phone a
        // Mac ticket can advertise a higher-priority `debugLoopback` (127.0.0.1)
        // route, and dialing that makes every secondary subscription connect to the
        // phone itself — so the Mac is unreachable and silently drops out of the
        // aggregate. Prefer the exact matching route, then any non-loopback, then any.
        let route = supportedRoutes.first(where: { route in
            if case let .hostPort(routeHost, routePort) = route.endpoint {
                return routeHost == host && routePort == port
            }
            return false
        }) ?? supportedRoutes.first(where: { $0.kind != .debugLoopback })
            ?? supportedRoutes.first
        guard let route else { return nil }
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: MobileShellRouteAuthPolicy.routeAllowsStackAuth(route),
            connectAttemptRegistry: connectAttemptRegistry,
            stackTokenGate: stackTokenGate,
            stackTokenForceRefreshGate: stackTokenForceRefreshGate
        )
        let capabilities = await fetchSecondaryHostCapabilities(on: client)
        return SecondaryClientHandle(
            client: client,
            route: route,
            ticket: ticket,
            supportedHostCapabilities: capabilities,
            actionCapabilities: Self.workspaceActionCapabilities(from: capabilities)
        )
    }

    private func fetchSecondaryHostCapabilities(on client: MobileCoreRPCClient) async -> Set<String> {
        guard let runtime else { return [] }
        do {
            let data = try await client.sendRequest(
                MobileCoreRPCClient.requestData(method: "mobile.host.status", params: [:]),
                timeoutNanoseconds: runtime.pairingRequestTimeoutNanoseconds
            )
            guard let payload = try? MobileHostStatusResponse.decode(data) else { return [] }
            return Set(payload.capabilities)
        } catch {
            mobileShellLog.warning("secondary host status failed: \(String(describing: error), privacy: .private)")
            return []
        }
    }

    /// Fetch one Mac's workspace list over an EXISTING client, tagged with its
    /// `macDeviceID`. Nil on any failure (best-effort; an unreachable Mac just
    /// contributes nothing).
    private func fetchSecondaryWorkspaces(
        on client: MobileCoreRPCClient,
        macDeviceID: String
    ) async -> [MobileWorkspacePreview]? {
        guard let runtime else { return nil }
        do {
            let requestData = try MobileCoreRPCClient.requestData(method: "workspace.list", params: [:])
            let resultData = try await client.sendRequest(
                requestData,
                timeoutNanoseconds: runtime.pairingRequestTimeoutNanoseconds
            )
            let response = try MobileSyncWorkspaceListResponse.decode(resultData)
            return response.workspaces.map { remote in
                var workspace = MobileWorkspacePreview(remote: remote)
                workspace.macDeviceID = macDeviceID
                return workspace
            }
        } catch {
            mobileShellLog.warning(
                "secondary workspace fetch failed mac=\(macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    /// Ensure a live read-only subscription exists for every signed-in paired Mac
    /// that is NOT the foreground connection, and drop subscriptions for Macs that
    /// disappeared or became the foreground. Each subscription keeps its
    /// ``workspacesByMac`` entry current via `workspace.updated` (slice 3); the
    /// derived ``workspaces`` recomputes automatically. Idempotent and best-effort:
    /// safe to call repeatedly (attach, pull-to-refresh, foreground).
    /// True while the multi-Mac aggregation is still running for the captured
    /// account/team scope and was not cancelled: signed in, the signed-in user is
    /// unchanged, and no Stack team switch bumped the scope generation. Mutating
    /// per-Mac aggregation state (`secondaryMacSubscriptions` / `workspacesByMac`)
    /// after a sign-out, account switch, or team switch would leak old-scope Macs
    /// into the new UI, so every mutation below is gated on this after each await.
    private func isAggregationScopeValid(_ scope: MobileShellScopeSnapshot) async -> Bool {
        guard !Task.isCancelled else { return false }
        return await isScopeCurrent(scope)
    }

    /// Launch the multi-Mac aggregation in a tracked task so sign-out / account
    /// switch can cancel it (its scope guards then bail before any cross-account
    /// write). Replaces any prior in-flight pass.
    private func scheduleSecondaryAggregation() {
        secondaryAggregationTask?.cancel()
        secondaryAggregationTask = Task { [weak self] in await self?.refreshSecondaryMacWorkspaces() }
    }

    func refreshSecondaryMacWorkspaces() async {
        guard let pairedMacStore, multiMacAggregationEnabled else { return }
        // Require a concrete signed-in user before any load/connection: a nil/empty
        // account would make `loadAll(stackUserID: nil)` read EVERY locally stored
        // Mac across Stack accounts and publish another account's workspaces into
        // this UI (the scope guard alone passes for nil == nil). Mirrors
        // loadPairedMacs()'s account requirement.
        guard let scope = await currentScopeSnapshot() else { return }
        // Pull the authoritative backup first so a secondary Mac that relaunched
        // on a new port has its route refreshed before we (re)connect.
        if let refresher = pairedMacStore as? any PairedMacBackupRefreshing {
            await refresher.refreshFromBackup(stackUserID: scope.userID)
        }
        guard await isAggregationScopeValid(scope) else { return }
        let loadedMacs = (try? await pairedMacStore.loadAll(stackUserID: scope.userID, teamID: scope.teamID)) ?? []
        guard await isAggregationScopeValid(scope) else { return }
        let visibleLoadedMacs = await visibleStoredPairedMacs(from: loadedMacs, scope: scope)
        guard await isAggregationScopeValid(scope) else { return }
        let macs = secondaryAggregationCandidateMacs(from: visibleLoadedMacs)
        let wanted = Set(macs.map(\.macDeviceID))
        // Tear down subscriptions for Macs that are gone or are now the foreground.
        for (macID, subscription) in secondaryMacSubscriptions where !wanted.contains(macID) {
            subscription.cancel()
            secondaryMacSubscriptions[macID] = nil
            workspacesByMac[macID] = nil
        }
        // For each wanted secondary Mac: establish a fresh subscription, or — if
        // one already exists — reseed its snapshot over the existing client so an
        // explicit refresh (foreground/pull) still updates a stream that was
        // suspended while backgrounded or whose pushes never started. If the
        // existing client is dead, recreate the subscription.
        for mac in macs where wanted.contains(mac.macDeviceID) {
            // Re-check before each Mac so a sign-out / account/team switch
            // mid-loop stops us before we connect to or write state for another
            // scope.
            guard await isAggregationScopeValid(scope) else { return }
            if let existing = secondaryMacSubscriptions[mac.macDeviceID] {
                let previews = await fetchSecondaryWorkspaces(on: existing.client, macDeviceID: mac.macDeviceID)
                guard await isSecondaryRefreshStillCurrent(
                    macDeviceID: mac.macDeviceID,
                    subscription: existing,
                    scope: scope
                ) else { continue }
                if let previews {
                    workspacesByMac[mac.macDeviceID] = MacWorkspaceState(
                        macDeviceID: mac.macDeviceID,
                        displayName: mac.displayName,
                        workspaces: previews,
                        status: .connected,
                        actionCapabilities: existing.actionCapabilities
                    )
                } else {
                    existing.cancel()
                    secondaryMacSubscriptions[mac.macDeviceID] = nil
                    markSecondaryMacUnavailable(mac.macDeviceID)
                    await establishSecondaryMacSubscription(
                        for: mac, scope: scope)
                }
            } else {
                await establishSecondaryMacSubscription(
                    for: mac, scope: scope)
            }
        }
    }

    private func isSecondaryRefreshStillCurrent(
        macDeviceID: String,
        subscription: SecondaryMacSubscription,
        scope: MobileShellScopeSnapshot
    ) async -> Bool {
        guard await isAggregationScopeValid(scope),
              secondaryMacSubscriptions[macDeviceID] === subscription else {
            return false
        }
        return await !isForgottenMacDeviceID(macDeviceID, scope: scope)
    }

    private func isSecondaryMacStillVisible(
        _ macDeviceID: String,
        scope: MobileShellScopeSnapshot
    ) async -> Bool {
        guard await isAggregationScopeValid(scope) else { return false }
        return await !isForgottenMacDeviceID(macDeviceID, scope: scope)
    }

    func secondaryAggregationCandidateMacIDs() async -> [String] {
        guard let pairedMacStore,
              let scope = await currentScopeSnapshot() else { return [] }
        let loadedMacs = (try? await pairedMacStore.loadAll(stackUserID: scope.userID, teamID: scope.teamID)) ?? []
        let visibleLoadedMacs = await visibleStoredPairedMacs(from: loadedMacs, scope: scope)
        guard await isAggregationScopeValid(scope) else { return [] }
        return secondaryAggregationCandidateMacs(from: visibleLoadedMacs).map(\.macDeviceID)
    }

    private func secondaryAggregationCandidateMacs(from visibleLoadedMacs: [MobilePairedMac]) -> [MobilePairedMac] {
        let macs = Self.coalescePairedMacsByDialEndpoint(
            visibleLoadedMacs,
            supportedKinds: runtime?.supportedRouteKinds ?? [],
            preferNonLoopback: Self.prefersNonLoopbackRoutes
        )
        let foregroundMacDeviceIDs = foregroundMacDeviceID.map {
            Self.macDeviceIDsForLogicalPairedMac(
                $0,
                in: visibleLoadedMacs,
                supportedKinds: runtime?.supportedRouteKinds ?? [],
                preferNonLoopback: Self.prefersNonLoopbackRoutes
            )
        } ?? []
        let foregroundIDSet = Set(foregroundMacDeviceIDs)
        return macs.filter { !$0.macDeviceID.isEmpty && !foregroundIDSet.contains($0.macDeviceID) }
    }

    /// Open a persistent read-only connection to `mac`, seed its workspace state,
    /// then run a live `workspace.updated` consumer that re-fetches its list on
    /// each change. Fully best-effort: on any failure the entry is torn down and
    /// the pull-to-refresh / foreground re-aggregate path remains the fallback, so
    /// a secondary subscription can never crash or block the foreground.
    private func establishSecondaryMacSubscription(
        for mac: MobilePairedMac,
        scope: MobileShellScopeSnapshot
    ) async {
        let macID = mac.macDeviceID
        guard secondaryMacSubscriptions[macID] == nil else { return }
        guard let handle = await makeSecondaryClient(for: mac) else {
            guard await isSecondaryMacStillVisible(macID, scope: scope) else { return }
            markSecondaryMacUnavailable(macID)
            return
        }
        let client = handle.client
        // Re-check after the async client build so a concurrent refresh cannot
        // open a duplicate connection, AND so a sign-out / account/team switch
        // during the connect does not leave an old-scope connection live or write
        // its state; the loser disconnects its client.
        guard secondaryMacSubscriptions[macID] == nil,
              await isSecondaryMacStillVisible(macID, scope: scope) else {
            await client.disconnect()
            return
        }
        let subscription = SecondaryMacSubscription(
            macDeviceID: macID,
            client: client,
            route: handle.route,
            ticket: handle.ticket,
            supportedHostCapabilities: handle.supportedHostCapabilities,
            actionCapabilities: handle.actionCapabilities
        )
        secondaryMacSubscriptions[macID] = subscription
        let displayName = mac.displayName
        let previews = await fetchSecondaryWorkspaces(on: client, macDeviceID: macID)
        // The fetch await is another sign-out window: drop the just-opened
        // connection and entry rather than seed another account's workspaces.
        guard await isAggregationScopeValid(scope),
              secondaryMacSubscriptions[macID] === subscription else {
            subscription.cancel()
            if secondaryMacSubscriptions[macID] === subscription {
                secondaryMacSubscriptions[macID] = nil
            }
            return
        }
        if let previews {
            workspacesByMac[macID] = MacWorkspaceState(
                macDeviceID: macID,
                displayName: displayName,
                workspaces: previews,
                status: .connected,
                actionCapabilities: subscription.actionCapabilities
            )
        } else {
            markSecondaryMacUnavailable(macID)
        }
        await flushPendingNotificationDismisses(macDeviceID: macID)
        subscription.task = Task { @MainActor [weak self] in
            let stream = await client.subscribe(to: ["workspace.updated"])
            await self?.enableSecondaryEventSubscription(on: client, streamID: subscription.streamID)
            for await event in stream {
                guard let self, !Task.isCancelled else { break }
                // Stop if this subscription was replaced/torn down.
                guard self.secondaryMacSubscriptions[macID]?.client === client else { break }
                if event.topic == "workspace.updated" {
                    // Coalesced, newest-wins refresh: a title/progress churn stream
                    // collapses to at most one in-flight + one trailing full-list
                    // scan instead of one scan per event (mirrors the foreground's
                    // workspaceListRefreshTask coalescing).
                    self.scheduleSecondaryRefresh(macID: macID, client: client, displayName: displayName)
                }
            }
            // Stream ended (disconnect / error): tear the subscription down so a
            // later refresh can re-establish it, and DOWNGRADE this Mac's workspace
            // state to offline so the aggregate stops showing its rows as live. The
            // rows stay visible (marked unavailable) rather than vanishing, and the
            // pull-to-refresh / foreground re-aggregate path re-establishes the Mac.
            guard let self, self.secondaryMacSubscriptions[macID]?.client === client else { return }
            self.secondaryMacSubscriptions[macID] = nil
            self.markSecondaryMacUnavailable(macID)
            await client.disconnect()
        }
    }

    /// Downgrade retained secondary rows without dropping them from the
    /// aggregate. A failed refresh/reconnect should make stale rows visibly
    /// unavailable, not leave them connected/actionable until a stream callback
    /// happens to run.
    private func markSecondaryMacUnavailable(_ macID: String) {
        guard var state = workspacesByMac[macID] else { return }
        state.status = .unavailable
        workspacesByMac[macID] = state
    }

    /// Coalesced full-list refresh for a secondary Mac driven by
    /// `workspace.updated` pushes. Leading + trailing: if a refresh is already
    /// running we only flag a trailing pass, so a hot event stream collapses to
    /// at most one extra scan after the in-flight one (not one scan, and one
    /// MainActor aggregate update, per event). Bounded — each fetch completes
    /// before the next starts, so there is no cancel/restart starvation.
    private func scheduleSecondaryRefresh(
        macID: String,
        client: MobileCoreRPCClient,
        displayName: String?
    ) {
        guard let subscription = secondaryMacSubscriptions[macID],
              subscription.client === client else { return }
        guard subscription.refreshTask == nil else {
            subscription.refreshPending = true
            return
        }
        subscription.refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                // Clear before the fetch; an event during the await re-sets it and
                // we loop once more (the trailing refresh).
                self.secondaryMacSubscriptions[macID]?.refreshPending = false
                let previews = await self.fetchSecondaryWorkspaces(on: client, macDeviceID: macID)
                // Bail if the subscription was replaced/torn down across the await.
                guard let current = self.secondaryMacSubscriptions[macID],
                      current.client === client else { return }
                if let previews {
                    self.workspacesByMac[macID] = MacWorkspaceState(
                        macDeviceID: macID,
                        displayName: displayName,
                        workspaces: previews,
                        status: .connected,
                        actionCapabilities: current.actionCapabilities
                    )
                }
            } while self.secondaryMacSubscriptions[macID]?.refreshPending == true
            self.secondaryMacSubscriptions[macID]?.refreshTask = nil
        }
    }

    /// Routing target for a workspace mutation (rename / pin / unread / close): the
    /// connection that owns `id` in the aggregated multi-Mac list.
    ///
    /// - `client == remoteClient`, `isForeground == true` for a foreground-owned
    ///   row, a single-Mac session, or an anonymous/manual host (owner unknown).
    /// - the live secondary connection for a row owned by another aggregated Mac.
    /// - `client == nil` when the owner is a known non-foreground Mac that has no
    ///   live connection right now, so the caller must NOT fall back to the
    ///   foreground client (that is exactly the wrong-Mac bug this avoids).
    func workspaceMutationTarget(for id: MobileWorkspacePreview.ID) -> WorkspaceMutationTarget {
        let owner = workspaces.first(where: { $0.id == id })?.macDeviceID
        if owner == nil || owner == foregroundMacDeviceID || owner == Self.foregroundAnonymousKey {
            return WorkspaceMutationTarget(
                client: remoteClient, isForeground: true, macDeviceID: foregroundMacDeviceID)
        }
        if let owner, let sub = secondaryMacSubscriptions[owner] {
            return WorkspaceMutationTarget(client: sub.client, isForeground: false, macDeviceID: owner)
        }
        return WorkspaceMutationTarget(client: nil, isForeground: false, macDeviceID: owner)
    }

    /// Re-sync the authoritative workspace list for the Mac a mutation actually hit:
    /// the foreground's coalesced refresh, or the owning secondary's coalesced
    /// re-fetch (so a pin/close on a secondary row snaps to the Mac's real state).
    func refreshAfterWorkspaceMutation(_ target: WorkspaceMutationTarget) async {
        if target.isForeground {
            await refreshWorkspaces()
        } else if let macID = target.macDeviceID, let sub = secondaryMacSubscriptions[macID] {
            scheduleSecondaryRefresh(
                macID: macID, client: sub.client, displayName: workspacesByMac[macID]?.displayName)
        }
    }

    /// Fire the server-side `mobile.events.subscribe` enable for a secondary
    /// connection's `workspace.updated` stream. Best-effort; the consumer loop
    /// runs regardless and a failure just means no live pushes for that Mac.
    private func enableSecondaryEventSubscription(on client: MobileCoreRPCClient, streamID: String) async {
        guard let request = try? MobileCoreRPCClient.requestData(
            method: "mobile.events.subscribe",
            params: ["stream_id": streamID, "topics": ["workspace.updated"]]
        ) else { return }
        _ = try? await client.sendRequest(request)
    }

    /// Cancel and disconnect every secondary subscription (sign-out / full reset),
    /// and cancel any in-flight aggregation pass so it cannot resume and re-seed
    /// the torn-down entries for a now-signed-out / switched account.
    private func teardownSecondaryMacSubscriptions() {
        secondaryAggregationTask?.cancel()
        secondaryAggregationTask = nil
        for (_, subscription) in secondaryMacSubscriptions { subscription.cancel() }
        secondaryMacSubscriptions.removeAll()
    }

    /// Whether the multi-Mac aggregated workspace list is enabled. Env override,
    /// then UserDefaults, then DEBUG on / Release off — so the aggregation (still
    /// being hardened) ships dark in Release and the single-Mac list is the exact
    /// prior behavior unless explicitly turned on.
    private var multiMacAggregationEnabled: Bool {
        if let raw = ProcessInfo.processInfo.environment["CMUX_MULTI_MAC_AGGREGATION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return ["1", "true", "yes", "on"].contains(raw.lowercased())
        }
        if multiMacAggregationDefaults.object(forKey: "multiMacAggregation") != nil {
            return multiMacAggregationDefaults.bool(forKey: "multiMacAggregation")
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Sentinel key for the foreground Mac when its attach ticket carries no
    /// macDeviceID (anonymous / manual host). Keeps the foreground entry in
    /// ``workspacesByMac`` addressable even without a real device id.
    static let foregroundAnonymousKey = "__cmux_foreground__"

    /// The key the foreground Mac's state lives under in ``workspacesByMac``.
    private var foregroundMacKey: String { foregroundMacDeviceID ?? Self.foregroundAnonymousKey }

    private func updateForegroundWorkspaceActionCapabilities() {
        guard var state = workspacesByMac[foregroundMacKey] else { return }
        state.actionCapabilities = Self.workspaceActionCapabilities(from: supportedHostCapabilities)
        workspacesByMac[foregroundMacKey] = state
    }

    /// Recompute the derived ``workspaces`` / ``workspaceGroups`` from the per-Mac
    /// source of truth. Pure and cheap; the only place those two are assigned,
    /// called on any ``workspacesByMac`` or foreground change.
    private func recomputeDerivedWorkspaceState() {
        let previousSelection = selectedWorkspaceID.flatMap { id in
            workspaces.first { $0.id == id }
        }
        let foregroundKey: String?
        if let id = foregroundMacDeviceID, workspacesByMac[id] != nil {
            foregroundKey = id
        } else if workspacesByMac[Self.foregroundAnonymousKey] != nil {
            foregroundKey = Self.foregroundAnonymousKey
        } else {
            foregroundKey = nil
        }
        var derived = workspaceAggregation.derivedWorkspaces(
            statesByMac: workspacesByMac, foregroundMacDeviceID: foregroundKey)
        // Stamp per-Mac user color/icon overrides from pairedMacs so every
        // workspace avatar matches its computer's customization (same place the
        // aggregation already assigned the automatic color index).
        let customByMac = pairedMacCustomizationsByAliasID()
        if !customByMac.isEmpty {
            derived = derived.map { workspace in
                guard let macID = workspace.macDeviceID, let mac = customByMac[macID] else { return workspace }
                var copy = workspace
                copy.machineCustomColor = mac.customColor
                copy.machineCustomIcon = mac.customIcon
                return copy
            }
        }
        if foregroundKey == Self.foregroundAnonymousKey {
            derived = derived.map { workspace in
                guard workspace.macDeviceID == Self.foregroundAnonymousKey else { return workspace }
                var copy = workspace
                copy.macDeviceID = nil
                copy.machineColorIndex = nil
                return copy
            }
        }
        workspaces = derived
        pruneChatSessionSnapshots(to: derived)
        if let selectedWorkspaceID,
           !derived.contains(where: { $0.id == selectedWorkspaceID }) {
            let remapped = previousSelection.flatMap { previous in
                derived.first {
                    $0.rpcWorkspaceID == previous.rpcWorkspaceID
                        && $0.macDeviceID == previous.macDeviceID
                }
            }
            self.selectedWorkspaceID = remapped?.id ?? derived.first?.id
        }
        workspaceGroups = workspaceAggregation.derivedGroups(
            statesByMac: workspacesByMac, foregroundMacDeviceID: foregroundKey)
    }

    private func pruneChatSessionSnapshots(to visibleWorkspaces: [MobileWorkspacePreview]) {
        var validWorkspaceIDs = Set<String>()
        for workspace in visibleWorkspaces {
            let remoteID = workspace.remoteWorkspaceID ?? workspace.id
            validWorkspaceIDs.insert(workspace.id.rawValue)
            validWorkspaceIDs.insert(remoteID.rawValue)
            if let macDeviceID = workspace.macDeviceID {
                validWorkspaceIDs.insert(
                    workspaceAggregation.rowID(macDeviceID: macDeviceID, workspaceID: remoteID).rawValue
                )
            }
        }
        chatSessionSnapshotsByWorkspaceID = chatSessionSnapshotsByWorkspaceID.filter {
            validWorkspaceIDs.contains($0.key)
        }
    }

    /// Set the user's per-Mac customizations (name / color / icon), persist them
    /// locally, sync them to the per-user backup (so the user's other devices get
    /// them), and re-derive so the workspace avatars + Computers screen update.
    /// Empty strings are normalized to `nil` (cleared).
    public func updateMacCustomization(
        macDeviceID: String,
        customName: String?,
        customColor: String?,
        customIcon: String?
    ) async {
        func normalized(_ s: String?) -> String? {
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t?.isEmpty == false) ? t : nil
        }
        guard let scope = await currentScopeSnapshot() else { return }
        let name = normalized(customName), color = normalized(customColor), icon = normalized(customIcon), now = Date()
        do {
            try await pairedMacStore?.setCustomization(macDeviceID: macDeviceID, customName: name, customColor: color, customIcon: icon, stackUserID: scope.userID, teamID: scope.teamID, now: now)
        } catch {
            mobileShellLog.error("setCustomization failed mac=\(macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
        await loadPairedMacs()
        recomputeDerivedWorkspaceState()
    }

    /// Replace or merge the foreground Mac's workspace state. The single seam the
    /// foreground sync stream writes through, so the foreground entry is always
    /// keyed by ``foregroundMacKey`` and its rows stamped with the real device id
    /// (when known) for the machine filter. `groups == nil` leaves groups as-is
    /// (a merge/single-entry refresh omits them).
    private func setForegroundWorkspaceState(
        workspaces newWorkspaces: [MobileWorkspacePreview],
        groups: [MobileWorkspaceGroupPreview]?,
        merge: Bool
    ) {
        let key = foregroundMacKey
        let stamped = newWorkspaces.map { workspace -> MobileWorkspacePreview in
            // These are the FOREGROUND Mac's workspaces, so stamp them ALL with the
            // resolved foreground id — overriding any synthetic `manual-<host>:<port>`
            // id the active ticket carried for a Mac without
            // `mobile.attach_ticket.create`. Restamping only nil ids left those rows
            // owned by the synthetic id while the aggregate key was the real Mac id,
            // so the same machine looked like a different Mac (wrong counts /
            // customizations, and `openWorkspace` trying to switch to a nonexistent
            // Mac). When there is no foreground id (anonymous), leave rows unstamped
            // to match the anonymous key.
            guard let id = foregroundMacDeviceID else { return workspace }
            var copy = workspace
            copy.macDeviceID = id
            return copy
        }
        var state = workspacesByMac[key] ?? MacWorkspaceState(macDeviceID: key)
        if merge {
            var merged = state.workspaces
            for workspace in stamped {
                if let index = merged.firstIndex(where: { $0.id == workspace.id }) {
                    merged[index] = workspace
                } else {
                    merged.append(workspace)
                }
            }
            state.workspaces = merged
        } else {
            state.workspaces = stamped
        }
        if let groups { state.groups = groups }
        state.status = .connected
        state.actionCapabilities = Self.workspaceActionCapabilities(from: supportedHostCapabilities)
        workspacesByMac[key] = state
    }

    #if DEBUG
    /// Test seam: seed the foreground Mac's workspaces/groups (the per-Mac source
    /// of truth) so the derived ``workspaces``/``workspaceGroups`` reflect them,
    /// for tests downstream of the list that do not run a live connection.
    func setWorkspacesForTesting(
        _ workspaces: [MobileWorkspacePreview],
        groups: [MobileWorkspaceGroupPreview] = []
    ) {
        setForegroundWorkspaceState(workspaces: workspaces, groups: groups, merge: false)
    }

    /// Test seam: seed the full per-Mac workspace source of truth so aggregation
    /// edge cases can be tested without opening live secondary transports.
    func setWorkspaceStatesForTesting(
        _ states: [String: MacWorkspaceState],
        foregroundMacDeviceID: String?
    ) {
        self.foregroundMacDeviceID = foregroundMacDeviceID
        workspacesByMac = states
    }

    /// Test seam for the secondary-refresh failure path: stale rows should stay
    /// visible but become unavailable when a secondary Mac cannot be reached.
    func markSecondaryMacUnavailableForTesting(_ macID: String) {
        markSecondaryMacUnavailable(macID)
    }
    func foregroundMacDeviceIDForTesting() -> String? { foregroundMacDeviceID }
    func storedMacReconnectGenerationForTesting() -> Int { storedMacReconnectGeneration }
    #endif

    func invalidateStoredMacReconnectAttempt() { storedMacReconnectGeneration &+= 1 }

    /// Drop the PREVIOUS foreground/anonymous workspace snapshot from the aggregate
    /// after the foreground Mac changes (switch A→B, promotion, or a real connect
    /// after an anonymous/sign-out session). Its live client was just replaced, so
    /// those rows are stale; left in place, `recomputeDerivedWorkspaceState` (which
    /// derives over every `workspacesByMac` entry) keeps showing the old Mac's rows
    /// and can route actions/opens through stale ownership — the regression the
    /// pre-aggregation `workspaces = remoteWorkspaces` full replacement avoided.
    ///
    /// Only the OLD foreground key is removed. A live secondary is never keyed under
    /// the foreground id (aggregation excludes the foreground), and a reachable
    /// previous Mac is re-added as a secondary by the `scheduleSecondaryAggregation`
    /// the callers kick right after — so this never drops a real secondary's rows
    /// (including an intentionally-kept offline secondary).
    private func dropStalePreviousForeground(_ previousKey: String) {
        guard previousKey != foregroundMacKey,
              secondaryMacSubscriptions[previousKey] == nil else { return }
        let removedWorkspaceIDs = Set((workspacesByMac[previousKey]?.workspaces ?? []).flatMap { workspace in
            let remoteID = workspace.remoteWorkspaceID ?? workspace.id
            return [
                workspace.id.rawValue,
                remoteID.rawValue,
                workspaceAggregation.rowID(macDeviceID: previousKey, workspaceID: remoteID).rawValue,
            ]
        })
        workspacesByMac[previousKey] = nil
        for workspaceID in removedWorkspaceIDs {
            chatSessionSnapshotsByWorkspaceID[workspaceID] = nil
        }
    }

    /// Adopt a host-reported real device id as the foreground Mac's aggregate key.
    /// A compact/anonymous QR ticket connects with an empty `macDeviceID`, so the
    /// foreground state lands under the anonymous key with `foregroundMacDeviceID`
    /// nil. When `mobile.host.status` later reports the real id, move that state to
    /// the real id and stamp its rows — otherwise the Computers screen shows the
    /// connected Mac as "not connected" (foregroundMacDeviceID never matched) and
    /// secondary aggregation, which excludes `foregroundMacDeviceID`, can open a
    /// DUPLICATE read-only connection to the very Mac that is already foreground.
    private func adoptForegroundMacIdentity(_ macDeviceID: String) {
        guard !macDeviceID.isEmpty, foregroundMacDeviceID != macDeviceID else { return }
        let oldKey = foregroundMacKey
        foregroundMacDeviceID = macDeviceID
        guard oldKey != macDeviceID else { return }
        if var state = workspacesByMac[oldKey] {
            workspacesByMac[oldKey] = nil
            state.macDeviceID = macDeviceID
            state.workspaces = state.workspaces.map { workspace in
                var copy = workspace
                copy.macDeviceID = macDeviceID
                return copy
            }
            // Don't clobber a (somehow) pre-existing real-id entry; merge by keeping
            // the live foreground rows.
            workspacesByMac[macDeviceID] = state
        }
        if let connection = connections[oldKey] {
            connections[oldKey] = nil
            connections[macDeviceID] = connection
        }
    }

    /// Apply an optimistic mutation to the foreground Mac's workspace list (e.g. a
    /// just-created workspace or terminal) directly on the per-Mac source of
    /// truth, so the derived list reflects it immediately.
    private func mutateForegroundWorkspaces(_ body: (inout [MobileWorkspacePreview]) -> Void) {
        let key = foregroundMacKey
        var state = workspacesByMac[key] ?? MacWorkspaceState(macDeviceID: key)
        body(&state.workspaces)
        workspacesByMac[key] = state
    }

    /// Create a workspace locally or through the connected Mac, then select it.
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
        mutateForegroundWorkspaces { $0.append(workspace) }
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
        guard let workspace = workspaces.first(where: { $0.id == targetWorkspaceID }) else {
            return
        }
        selectedWorkspaceID = targetWorkspaceID
        let terminalIndex = workspace.terminals.count + 1
        let terminal = MobileTerminalPreview(
            id: .init(rawValue: "\(workspace.id.rawValue)-terminal-\(terminalIndex)"),
            name: L10n.terminalName(index: terminalIndex)
        )
        mutateForegroundWorkspaces { list in
            if let index = list.firstIndex(where: { $0.id == targetWorkspaceID }) {
                list[index].terminals.append(terminal)
            }
        }
        selectedTerminalID = terminal.id
        suppressTerminalAutoFocusOnNextAttach(for: terminal.id)
    }

    /// Select the active terminal by id without changing workspace selection.
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

    /// Record the latest measured terminal viewport for sizing future shell RPCs.
    public func reportTerminalViewport(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID,
        viewportSize: MobileTerminalViewportSize
    ) {
        let key = viewportKey(workspaceID: workspaceID, terminalID: terminalID)
        reportedViewportSizesByTerminalKey[key] = viewportSize
    }

    /// Open the workspace preview, switching the foreground Mac first when the workspace belongs to another paired Mac.
    public func openWorkspace(_ id: MobileWorkspacePreview.ID) async {
        let workspace = workspaces.first { $0.id == id }
        let remoteWorkspaceID = workspace?.rpcWorkspaceID ?? id
        let ownerMacDeviceID = workspace?.macDeviceID
        let workspaceHadUnread = workspace?.hasUnread == true
        // Cross-Mac open (P5): a workspace from the aggregated list may belong to
        // a Mac other than the current foreground connection. Switch the
        // foreground to that Mac first so the terminal attaches to the right one.
        if multiMacAggregationEnabled,
           let macDeviceID = ownerMacDeviceID,
           !macDeviceID.isEmpty,
           macDeviceID != foregroundMacDeviceID {
            // Only proceed if that Mac actually became the foreground connection.
            // The tap already selected this workspace and pushed its detail
            // synchronously (this runs from the detail's task), so on a failed
            // switch ROLL BACK the selection — popping the compact stack back to the
            // list — instead of leaving the user in a workspace whose Mac is not the
            // live connection (terminal input would route to the wrong client). The
            // offline row's Reconnect / the next aggregation pass recovers it.
            guard await switchToMac(macDeviceID: macDeviceID) else {
                mobileShellLog.error("openWorkspace: switch to mac failed, popping mac=\(macDeviceID, privacy: .public)")
                if selectedWorkspaceID == id {
                    setSelectedWorkspaceID(nil)
                }
                return
            }
        }
        let resolvedRowID = rowWorkspaceID(
            forRemoteWorkspaceID: remoteWorkspaceID,
            macDeviceID: ownerMacDeviceID
        ) ?? (workspaces.contains(where: { $0.id == id }) ? id : nil)
        guard let resolvedRowID else {
            mobileShellLog.error("openWorkspace: workspace disappeared after switch id=\(remoteWorkspaceID.rawValue, privacy: .private) mac=\(ownerMacDeviceID ?? "", privacy: .public)")
            if selectedWorkspaceID == id {
                setSelectedWorkspaceID(nil)
            }
            return
        }
        analytics.capture("ios_workspace_opened", [
            "terminal_count": .int(workspace?.terminals.count ?? 0),
            "is_pinned": .bool(workspace?.isPinned ?? false),
            "source": .string("list_tap"),
        ])
        setSelectedWorkspaceID(resolvedRowID)
        // Tapping into a workspace is a read receipt: clear its unread on the Mac
        // (like opening a thread marks it read), so it drops out of the unread
        // list and the back-button count. Only when the Mac advertises read-state
        // actions and the workspace is actually unread, so older Macs and
        // already-read workspaces send nothing.
        if supportsWorkspaceReadStateActions, workspaceHadUnread {
            await setWorkspaceUnread(id: resolvedRowID, false)
        }
    }

    /// Submit the current terminal input text from a synchronous UI action.
    public func sendTerminalInput() {
        Task { @MainActor [weak self] in
            await self?.submitTerminalInput()
        }
    }

    /// Submit the current terminal input text to the selected terminal.
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

    /// The pending image attachments for a terminal, in pick order. Empty when
    /// none are staged. Drives the composer's chip row.
    /// - Parameter terminalID: The terminal whose attachments to read; `nil`
    ///   falls back to the selected terminal.
    public func pendingAttachments(forTerminalID terminalID: String? = nil) -> [MobilePendingAttachment] {
        guard let key = terminalID ?? selectedTerminalID?.rawValue else { return [] }
        return pendingAttachmentsByTerminalID[key] ?? []
    }

    /// Stage a picked image as a pending attachment for a terminal, appended in
    /// pick order so it sends after earlier picks. A no-op when the bytes are
    /// empty.
    /// - Parameters:
    ///   - data: The encoded image bytes (PNG/JPEG), already under the size cap.
    ///   - format: A lowercase format hint (`"png"`/`"jpg"`).
    ///   - terminalID: The terminal to stage under; `nil` falls back to the
    ///     selected terminal.
    /// - Returns: The new attachment's stable id, so the caller can key a side
    ///   cache (e.g. a downsampled thumbnail) to it; `nil` when nothing was
    ///   staged (empty bytes, no target terminal, an over-cap single image, an
    ///   add that would exceed the per-terminal count or total-byte budget, or one
    ///   that would exceed the GLOBAL all-terminals count or byte budget).
    ///
    /// The count and total-byte caps are enforced HERE against the current staged
    /// set, not against a caller-side pre-await snapshot, so the check+insert is
    /// atomic on the main actor: if the user opens the picker again while a prior
    /// batch is still encoding, both batches funnel through this one mutation
    /// path and the second add re-reads the (already-grown) set, so the combined
    /// total can never exceed the cap. The store is the single source of truth.
    @discardableResult
    public func addPendingAttachment(_ data: Data, format: String, forTerminalID terminalID: String? = nil) -> MobilePendingAttachment.ID? {
        guard !data.isEmpty, let key = terminalID ?? selectedTerminalID?.rawValue else { return nil }
        // Reject any add for a terminal that is not in the current topology, so a
        // closed/recreated/stale id can never accrue orphaned bytes the user can no
        // longer see or send. This is the single validated path: both the base
        // call and the session-guarded variant funnel through here.
        guard terminalExistsInTopology(key) else { return nil }
        // A single image larger than the per-image cap is rejected outright.
        guard data.count <= Self.maxPendingAttachmentImageBytes else { return nil }
        let existing = pendingAttachmentsByTerminalID[key] ?? []
        // Count cap, computed against the CURRENT staged set (atomic on @MainActor).
        guard existing.count < Self.maxPendingAttachmentCount else { return nil }
        // Total-byte budget, likewise against the current set.
        let currentBytes = existing.reduce(0) { $0 + $1.data.count }
        guard currentBytes + data.count <= Self.maxPendingAttachmentTotalBytes else { return nil }
        // GLOBAL caps, summed across ALL terminals' staged sets (not just the
        // target's). The per-terminal checks above bound one draft, but each live
        // terminal keeps its own per-terminal budget, so without a global cap
        // staging across many terminals/workspaces grows unbounded with terminal
        // count and can OOM. Summing all keys at insert time is consistent because
        // this whole add path runs on @MainActor: no other mutation interleaves.
        // A hard reject (no eviction) keeps the invariant simple and testable.
        var globalCount = 0
        var globalBytes = 0
        for list in pendingAttachmentsByTerminalID.values {
            globalCount += list.count
            for item in list { globalBytes += item.data.count }
        }
        guard globalCount < Self.maxPendingAttachmentCountAllTerminals else { return nil }
        guard globalBytes + data.count <= Self.maxPendingAttachmentTotalBytesAllTerminals else { return nil }
        let attachment = MobilePendingAttachment(data: data, format: format)
        pendingAttachmentsByTerminalID[key, default: []].append(attachment)
        return attachment.id
    }

    /// A token identifying the current signed-in session. Capture it before an
    /// async photo load/encode and pass it back to
    /// ``addPendingAttachment(_:format:forTerminalID:ifSessionGeneration:)`` so a
    /// sign-out that lands mid-flight (which bumps the token) drops the stale
    /// result instead of staging the previous user's bytes under a terminal id the
    /// next account may reuse.
    public var currentSessionGeneration: Int { signInGeneration }

    /// Stage a picked image only if the captured session token still matches the
    /// current one, AND (when an explicit terminal id is given) that terminal
    /// still exists. Used by the composer's photo picker, whose load+encode runs
    /// off-main: a sign-out (or the target terminal going away) while that work is
    /// in flight must not re-stage the result. The token recheck lives in this
    /// store-mutation path so it is robust even if the picker view is already
    /// gone.
    /// - Parameter capturedGeneration: The value of
    ///   ``currentSessionGeneration`` read before the async work began.
    /// - Returns: The new attachment's id, or `nil` when nothing was staged
    ///   (empty bytes, no target terminal, a superseded session, or a terminal
    ///   that no longer exists).
    @discardableResult
    public func addPendingAttachment(
        _ data: Data,
        format: String,
        forTerminalID terminalID: String? = nil,
        ifSessionGeneration capturedGeneration: Int
    ) -> MobilePendingAttachment.ID? {
        // A sign-out (or account switch) bumped the token while the photo was
        // loading/encoding: this is the previous user's content, drop it.
        guard capturedGeneration == signInGeneration else { return nil }
        // For an explicit target, require it to still exist so a closed terminal
        // does not accrue orphaned bytes the user can no longer see or send. The
        // base add re-validates this for every path (including the selected-id
        // fallback), so existence is enforced once and only once below.
        if let terminalID, !terminalExistsInTopology(terminalID) {
            return nil
        }
        return addPendingAttachment(data, format: format, forTerminalID: terminalID)
    }

    /// Whether a terminal id is present in the current workspace/terminal
    /// topology. The single existence check both add paths share, so a stale id
    /// (closed or never-existed terminal) can never accrue staged bytes.
    private func terminalExistsInTopology(_ terminalID: String) -> Bool {
        workspaces.contains { $0.terminals.contains { $0.id.rawValue == terminalID } }
    }

    /// Drop staged attachments whose terminal id is no longer in the topology.
    /// Called from the ``workspaces`` `didSet` so a workspace/terminal sync that
    /// removes a terminal also releases its (potentially multi-MB) staged photo
    /// bytes instead of letting them accumulate until sign-out. The dictionary
    /// holds large `Data`, so unlike the externally-stored text draft it must be
    /// pruned in memory on every topology change.
    private func prunePendingAttachmentsForMissingTerminals() {
        guard !pendingAttachmentsByTerminalID.isEmpty else { return }
        let liveTerminalIDs: Set<String> = Set(
            workspaces.flatMap { $0.terminals.map(\.id.rawValue) }
        )
        pendingAttachmentsByTerminalID = pendingAttachmentsByTerminalID.filter {
            liveTerminalIDs.contains($0.key)
        }
    }

    /// Remove one staged attachment by id. A no-op when the id is not staged.
    /// - Parameters:
    ///   - id: The attachment's stable id.
    ///   - terminalID: The terminal it is staged under; `nil` falls back to the
    ///     selected terminal.
    public func removePendingAttachment(id: MobilePendingAttachment.ID, forTerminalID terminalID: String? = nil) {
        guard let key = terminalID ?? selectedTerminalID?.rawValue,
              var list = pendingAttachmentsByTerminalID[key] else { return }
        list.removeAll { $0.id == id }
        if list.isEmpty {
            pendingAttachmentsByTerminalID[key] = nil
        } else {
            pendingAttachmentsByTerminalID[key] = list
        }
    }

    /// Drop every staged attachment for a terminal (used after a successful send).
    /// - Parameter terminalID: The terminal to clear; `nil` falls back to the
    ///   selected terminal.
    public func clearPendingAttachments(forTerminalID terminalID: String? = nil) {
        guard let key = terminalID ?? selectedTerminalID?.rawValue else { return }
        pendingAttachmentsByTerminalID[key] = nil
    }

    /// Whether the composer's Send should be enabled: text is non-empty OR at
    /// least one attachment is staged. An attachments-only send (empty text) is
    /// allowed, so the gating cannot key on text alone.
    /// - Parameter terminalID: The terminal whose composer to gate; `nil` falls
    ///   back to the selected terminal.
    public func composerCanSend(forTerminalID terminalID: String? = nil) -> Bool {
        let textNonEmpty = !terminalInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return textNonEmpty || !pendingAttachments(forTerminalID: terminalID).isEmpty
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
        guard let workspaceID = selectedWorkspace?.id,
              let terminalID = selectedTerminalID else { return }
        await submitComposerInput(workspaceID: workspaceID, terminalID: terminalID)
    }

    /// Submit the composer's text to an explicitly captured terminal. Used by
    /// ``submitComposer()`` so a terminal switch mid-send cannot reroute the text
    /// to whatever is selected when the (awaited) image sends return: the target
    /// is captured once up front and threaded through here, while the draft
    /// reconciliation still keys on that captured terminal (not the live
    /// selection).
    ///
    /// - Parameter capturedText: The exact text to send, snapshotted by the
    ///   caller before any await. When `nil`, the live ``terminalInputText`` is
    ///   read (the text-only entry points have no earlier await, so there is no
    ///   snapshot to drift). ``submitComposer()`` MUST pass a snapshot: a terminal
    ///   switch or a field edit during its image awaits would otherwise make this
    ///   send (and the draft reconcile) read a different terminal's draft or skip
    ///   the text the user actually composed at Send time.
    ///
    /// - Returns: `true` when the Mac acknowledged the paste (or the text was
    ///   empty, i.e. nothing to send), `false` when the send failed so the caller
    ///   keeps the text for a retry.
    @discardableResult
    func submitComposerInput(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID,
        capturedText: String? = nil
    ) async -> Bool {
        let text = capturedText ?? terminalInputText
        // Empty text is "nothing to send", which is a success from the caller's
        // point of view (an images-only send has no text to keep on failure).
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        guard remoteClient != nil else { return false }
        // Reject a re-entrant send (e.g. a double tap on Send) so the same text
        // is not pasted twice. The flag is set/cleared on the main actor around
        // the await, so no second call can slip past it.
        guard !isSubmittingComposerInput else { return false }
        isSubmittingComposerInput = true
        defer { isSubmittingComposerInput = false }
        let sent = await sendRemoteTerminalPaste(
            text,
            submitKey: "return",
            workspaceID: workspaceID,
            terminalID: terminalID
        )
        guard sent else { return false }
        // Reconcile against the CAPTURED terminal, not the live selection: if the
        // user switched terminals while the ack was in flight, the switch persists
        // the outgoing text as the captured terminal's draft, and the sent text
        // must be cleared from that key, not from whatever terminal is selected
        // when the ack returns.
        await reconcileComposerDraftAfterSend(sentText: text, submittedTerminalID: terminalID)
        return true
    }

    /// Send the composer's staged attachments then its text, iMessage-style: the
    /// images are delivered first (in pick order) so their injected file paths
    /// land before the message that references them, then the text is submitted.
    /// Attachments for the submitted terminal are cleared once they have all been
    /// sent.
    ///
    /// Allowed with empty text as long as at least one attachment is staged; an
    /// images-only send skips the (no-op) text submit.
    ///
    /// Captures the target workspace + terminal ONCE up front and threads them
    /// through both the image sends and the text send, so a terminal switch while
    /// an (awaited) image send is in flight cannot reroute later images or the
    /// text to whatever is selected at that moment. Attachments are removed from
    /// the staged set one at a time, only after each send is acknowledged: a
    /// failed image send stops the run and keeps the remaining (and failed)
    /// attachments staged AND keeps the text unsent, so the user can retry
    /// instead of silently losing photos (matching the text-keep-on-failure
    /// semantics of ``submitComposerInput()``).
    public func submitComposer() async {
        // Reject a re-entrant submit (e.g. a double tap on Send): the button
        // stays enabled while the first image RPC awaits, and a second submit
        // would capture the same still-staged attachments and re-upload them.
        // Set/cleared on the main actor around the awaits, so no second call can
        // slip past. A failed send keeps the attachments staged (below), so the
        // user can retry once this flag clears.
        guard !isSubmittingComposer else { return }
        isSubmittingComposer = true
        defer { isSubmittingComposer = false }
        guard let workspaceID = selectedWorkspace?.id,
              let submittedTerminalID = selectedTerminalID else {
            // No target: fall back to the text-only path, which is itself a no-op
            // without a selected terminal.
            await submitComposerInput()
            return
        }
        // Snapshot the text BEFORE any await (the image sends below). Threaded
        // through the text submit + the post-send reconcile so a terminal switch
        // (which swaps the draft into a different terminal's text) or a field edit
        // while an image send is in flight cannot make the text send read the
        // wrong draft or skip the message the user composed at Send time. An
        // images-only send snapshots empty text, which the text submit no-ops.
        let submittedText = terminalInputText
        let attachments = pendingAttachments(forTerminalID: submittedTerminalID.rawValue)
        // Capture the submit-time session + connection identity ONCE up front and
        // re-check it before every subsequent send. The captured terminal already
        // pins the target surface, but it does NOT pin the session/transport the
        // bytes flow through: each image RPC is awaited, and a sign-out, account
        // switch, Mac switch, or reconnect that lands during that await replaces
        // `remoteClient` (and bumps these generations) WITHOUT cancelling this
        // loop. `sendRemoteTerminalPasteImage` returns true even when a superseded
        // connection answered, so without this guard the loop would keep going and
        // send the next staged image, then the captured text, through whatever
        // session is now current, leaking the previous user's / previous Mac's
        // unsent content into a different session. `signInGeneration` covers
        // sign-out + account switch; `connectionGeneration` covers Mac switch,
        // reconnect, and disconnect. On mismatch we abort the WHOLE submit (stop
        // the loop, do not send the text) and leave everything staged for a retry.
        let submitSignInGeneration = signInGeneration
        let submitConnectionGeneration = connectionGeneration
        // Deliver each image first and await it, so the agent's terminal has the
        // file paths before the text arrives. Remove each only after its send is
        // acknowledged; on failure stop and keep the rest (and the text) staged.
        for attachment in attachments {
            // Re-check the captured session/connection still matches before each
            // image send (the previous iteration's send was awaited). A mismatch
            // means the session or transport was replaced mid-submit; abort
            // without sending so nothing leaks into the new session. Attachments
            // are left staged (no removal happened for this iteration).
            guard isComposerSubmitIdentityCurrent(
                signIn: submitSignInGeneration,
                connection: submitConnectionGeneration
            ) else { return }
            // Re-check the attachment is still staged for the captured terminal
            // before uploading it. The user can delete a not-yet-acked chip while
            // an earlier image's send is in flight; that removes it from
            // `pendingAttachmentsByTerminalID`, but this loop iterates a snapshot
            // taken before the awaits. Skipping the removed one keeps the local
            // snapshot from re-uploading bytes the user already dismissed. Runs on
            // the @MainActor, so the membership check is consistent with the
            // removal.
            guard pendingAttachments(forTerminalID: submittedTerminalID.rawValue)
                .contains(where: { $0.id == attachment.id }) else { continue }
            let sent = await submitTerminalPasteImage(
                attachment.data,
                format: attachment.format,
                workspaceID: workspaceID,
                terminalID: submittedTerminalID
            )
            guard sent else { return }
            removePendingAttachment(id: attachment.id, forTerminalID: submittedTerminalID.rawValue)
        }
        // Re-check the captured identity one last time before the text send. The
        // final image's send was awaited above, so a sign-out / Mac switch /
        // reconnect could have landed after it; abort (keep the text staged in the
        // field) rather than paste the user's message into the now-current
        // session.
        guard isComposerSubmitIdentityCurrent(
            signIn: submitSignInGeneration,
            connection: submitConnectionGeneration
        ) else { return }
        // Submit the captured text to the captured terminal (a no-op when empty,
        // e.g. an images-only send). All images acked by here, so the text
        // follows. Passing the snapshot (not the live field) keeps this immune to
        // a switch/edit that happened during the image awaits above.
        await submitComposerInput(
            workspaceID: workspaceID,
            terminalID: submittedTerminalID,
            capturedText: submittedText
        )
    }

    /// Whether the session + connection identity captured at the start of a
    /// ``submitComposer()`` run still matches the current one. Re-checked before
    /// every image send and before the text send so a sign-out, account switch,
    /// Mac switch, or reconnect that lands while an (awaited) image RPC is in
    /// flight aborts the rest of the submit instead of routing the next image or
    /// the captured text through a now-current, different session.
    ///
    /// `signInGeneration` is bumped by ``signOut()`` (sign-out + account switch);
    /// `connectionGeneration` is bumped whenever the remote client/transport is
    /// replaced (Mac switch, reconnect, disconnect). Either bump invalidates the
    /// in-flight submit.
    ///
    /// Internal (not private) so tests can drive the captured-identity recheck.
    func isComposerSubmitIdentityCurrent(signIn: Int, connection: UUID) -> Bool {
        signIn == signInGeneration && connection == connectionGeneration
    }

    /// Bump the connection generation so any composer submit (or other
    /// generation-guarded operation) in flight against the previous connection is
    /// treated as superseded. Internal (not private) so a test can model a
    /// mid-submit connection swap that the pairing/reconnect flow performs in
    /// production without standing up the full handshake.
    func bumpConnectionGenerationForTesting() {
        connectionGeneration = UUID()
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

    /// Submit raw text to the currently selected terminal when one is available.
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
        allowsStackAuthFallback: Bool? = nil,
        pairedMacDeviceID: String? = nil
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
        // Stack auth is now the authorization gate for every request. Decide the
        // fallback per attempted route so an untrusted fallback route cannot
        // disable auth for a trusted Tailscale/loopback/iroh route.
        let routeAllowsStackAuthFallbackOverride = allowsStackAuthFallback
        let connectionAttemptStartedAt = pairingAttemptStartedAt
        var lastError: (any Error)?
        for route in supportedRoutes {
            activeRoute = route
            mobileShellLog.info("pairing trying route kind=\(route.kind.rawValue, privacy: .public) endpoint=\(route.endpoint.logDescription, privacy: .private)")
            let client = MobileCoreRPCClient(
                runtime: runtime,
                route: route,
                ticket: ticket,
                allowsStackAuthFallback: routeAllowsStackAuthFallbackOverride
                    ?? MobileShellRouteAuthPolicy.routeAllowsStackAuth(route),
                connectAttemptRegistry: connectAttemptRegistry,
                stackTokenGate: stackTokenGate,
                stackTokenForceRefreshGate: stackTokenForceRefreshGate
            )
            for workspaceListRequest in workspaceListRequests {
                do {
                    let requestTimeoutNanoseconds: UInt64
                    if let connectionAttemptStartedAt {
                        requestTimeoutNanoseconds = boundedPairingRequestTimeoutNanoseconds(
                            runtime: runtime,
                            attemptStartedAt: connectionAttemptStartedAt
                        )
                        guard requestTimeoutNanoseconds > 0 else {
                            throw MobileShellConnectionError.requestTimedOut
                        }
                    } else {
                        requestTimeoutNanoseconds = runtime.pairingRequestTimeoutNanoseconds
                    }
                    let resultData = try await client.sendRequest(
                        workspaceListRequest.data,
                        timeoutNanoseconds: requestTimeoutNanoseconds
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
                    // Set the foreground Mac id BEFORE applying the list so the
                    // per-Mac state is keyed to THIS Mac, not the previously-
                    // foreground Mac (or the anonymous key). Otherwise switching
                    // from Mac A to Mac B writes B's workspaces under A's key, and
                    // once the id flips the derived list reads a stale/empty B
                    // snapshot. Anonymous (empty-id) tickets keep the anonymous key. A
                    // manual fallback ticket carries a synthetic `manual-…` id, so
                    // prefer the caller's real paired-Mac id when it is known.
                    let resolvedForegroundMacID = ticket.foregroundMacID(hint: pairedMacDeviceID)
                    let previousForegroundKey = foregroundMacKey
                    if !resolvedForegroundMacID.isEmpty {
                        foregroundMacDeviceID = resolvedForegroundMacID
                    }
                    applyRemoteWorkspaceList(
                        response,
                        preferActiveTicketTarget: workspaceListRequest.preferActiveTicketTarget,
                        // Scoped requests omit groups; only a non-scoped (full) list
                        // is authoritative for the device-local collapse store.
                        groupsAreAuthoritative: !workspaceListRequest.isScoped
                    )
                    // Drop the now-stale previous-foreground/anonymous snapshot so it
                    // doesn't linger in the aggregate (it's re-added as a secondary
                    // below if still reachable).
                    dropStalePreviousForeground(previousForegroundKey)
                    syncSelectedTerminalForWorkspace()
                    connectionState = .connected
                    markMacConnectionHealthy()
                    // Record this as the foreground entry in the per-Mac
                    // connection pool (P2). Anonymous (empty-id) tickets are not
                    // pooled, since a per-Mac key is required to aggregate. Keyed by
                    // the resolved real id (not the synthetic manual ticket id) so the
                    // pool entry matches the foreground/aggregation key.
                    if !resolvedForegroundMacID.isEmpty {
                        connections[resolvedForegroundMacID] = MacConnection(
                            macDeviceID: resolvedForegroundMacID,
                            ticket: ticket,
                            route: firstRoute,
                            client: client,
                            generation: generation
                        )
                    }
                    // Aggregate the user's other Macs' workspaces in the
                    // background (no-op / off in Release). Best-effort; never
                    // blocks the foreground connect.
                    if multiMacAggregationEnabled {
                        self.scheduleSecondaryAggregation()
                    }
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
        let orderedRoutes = ticket.routes.sorted(by: Self.routeSortsBefore)
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
                preferActiveTicketTarget: selectedWorkspaceID == nil || selectedWorkspace?.rpcWorkspaceID == activeTicketWorkspaceID
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

    private func clearRemoteConnectionContext(preservingOtherMacWorkspaceState: Bool = false) {
        connectionGeneration = UUID()
        connectionAttemptGeneration = UUID()
        cancelRemoteOperationTasks()
        clearActiveConnectionContext()
        macConnectionStatus = .unavailable
        replaceRemoteClient(with: nil)
        // Drop the foreground entry from the connection pool (P2). Secondary
        // read-only connections (P3) are torn down separately.
        let offlineForegroundKey = foregroundMacKey
        if let foreground = foregroundMacDeviceID {
            connections[foreground] = nil
        }
        foregroundMacDeviceID = nil
        if !preservingOtherMacWorkspaceState {
            // Cancel the live secondary subscriptions (slice 3) and keep only the
            // now-offline foreground Mac's last-known workspaces for the offline
            // view; the derived list recomputes to just the offline Mac's rows.
            teardownSecondaryMacSubscriptions()
            workspacesByMac = workspacesByMac.filter { $0.key == offlineForegroundKey }
        }
        // The retained foreground entry still carries its last-known
        // `status: .connected`; `macConnectionStatuses` (the Computers screen's
        // per-Mac dots) derives from these per-Mac states, so without this the
        // just-disconnected Mac would keep showing a green connected dot. Downgrade
        // it to `.unavailable` to match the global connection state.
        if var offline = workspacesByMac[offlineForegroundKey] {
            offline.status = .unavailable
            workspacesByMac[offlineForegroundKey] = offline
        }
        rawTerminalInputBuffer.clear()
    }

    /// Set `remoteClient` to a new value (possibly nil) and disconnect the
    /// previous one so we don't leak a persistent transport.
    private func replaceRemoteClient(with newValue: MobileCoreRPCClient?) {
        let previous = remoteClient
        remoteClient = newValue
        if newValue != nil, previous !== newValue {
            chatEventSourceGeneration = UUID()
        }
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
        terminalActiveScreenBySurfaceID = [:]
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
                setSelectedWorkspaceID(rowWorkspaceID(
                    forRemoteWorkspaceID: createdWorkspace,
                    macDeviceID: foregroundMacDeviceID
                ) ?? createdWorkspace)
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
              let rowWorkspaceID = explicitWorkspaceID ?? selectedWorkspace?.id else { return }
        let requestedWorkspaceID = remoteWorkspaceID(for: rowWorkspaceID)
        let generation = connectionGeneration
        do {
            let resultData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "terminal.create",
                    params: ["workspace_id": requestedWorkspaceID.rawValue]
                )
            )
            let response = try MobileSyncWorkspaceListResponse.decode(resultData)
            guard isCurrentRemoteOperation(client: client, generation: generation),
                  !Task.isCancelled else { return }
            applyRemoteWorkspaceList(response, mergeExistingWorkspaces: true)
            if selectedWorkspaceID == rowWorkspaceID,
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
            let remoteWorkspaceID = remoteWorkspaceID(for: workspaceID)
            var params: [String: Any] = [
                "workspace_id": remoteWorkspaceID.rawValue,
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
            let remoteWorkspaceID = remoteWorkspaceID(for: workspaceID)
            var params: [String: Any] = [
                "workspace_id": remoteWorkspaceID.rawValue,
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
    /// - Returns: `true` when the Mac acknowledged the image, `false` on any
    ///   failure (no selection, no client, a stale generation, or an RPC error).
    @discardableResult
    public func submitTerminalPasteImage(_ data: Data, format: String) async -> Bool {
        guard let workspaceID = selectedWorkspace?.id,
              let terminalID = selectedTerminalID else {
            return false
        }
        return await submitTerminalPasteImage(
            data,
            format: format,
            workspaceID: workspaceID,
            terminalID: terminalID
        )
    }

    /// Send an image to an explicitly captured terminal. Used by
    /// ``submitComposer()`` so a mid-send terminal switch cannot reroute a later
    /// image to whatever is selected when the prior image's ack returns.
    ///
    /// - Returns: `true` when the Mac acknowledged the image, `false` on any
    ///   failure, so the caller keeps the attachment staged for a retry.
    @discardableResult
    func submitTerminalPasteImage(
        _ data: Data,
        format: String,
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) async -> Bool {
        guard !data.isEmpty else { return false }
        guard remoteClient != nil else { return false }
        return await sendRemoteTerminalPasteImage(
            data,
            format: format,
            workspaceID: workspaceID,
            terminalID: terminalID
        )
    }

    /// - Returns: `true` when the Mac acknowledged the image paste, `false` on
    ///   any failure (no client, a stale generation, or an RPC error such as an
    ///   oversized payload or `method_not_found` from an older host). Callers use
    ///   this to keep the staged attachment on failure instead of dropping it.
    @discardableResult
    private func sendRemoteTerminalPasteImage(
        _ data: Data,
        format: String,
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) async -> Bool {
        guard let client = remoteClient else { return false }
        let generation = connectionGeneration
        do {
            #if DEBUG
            mobileShellLog.debug("send remote terminal paste image byteCount=\(data.count, privacy: .public) format=\(format, privacy: .public)")
            #endif
            let remoteWorkspaceID = remoteWorkspaceID(for: workspaceID)
            let params: [String: Any] = [
                "workspace_id": remoteWorkspaceID.rawValue,
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
            // The Mac acked the image: treat it as applied even if a reconnect
            // superseded this client mid-flight (only the per-connection response
            // bookkeeping is generation-guarded), so a retry does not re-send the
            // same image.
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
            updateForegroundWorkspaceActionCapabilities()
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
                payload.terminalFidelity == "render_grid" ? .hybrid : .rawBytes
            terminalOutputTransport = transport
            MobileDebugLog.anchormux("sync.transport=\(transport.debugName)")
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
                } else if event.topic == "terminal.set_font" {
                    self.handleTerminalSetFontEvent(event)
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
        if terminalOutputTransport.usesRenderGrid,
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

    private func shouldDeliverRenderGridEvent(
        _ renderGrid: MobileTerminalRenderGridFrame,
        previous: MobileTerminalRenderGridFrame.Screen?
    ) -> Bool {
        guard terminalOutputTransport == .hybrid,
              renderGrid.activeScreen == .primary else {
            return true
        }
        return previous == .alternate
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
        let previousScreen = terminalActiveScreenBySurfaceID[renderGrid.surfaceID]
        terminalActiveScreenBySurfaceID[renderGrid.surfaceID] = renderGrid.activeScreen
        guard source != "event" || shouldDeliverRenderGridEvent(renderGrid, previous: previousScreen) else {
            deliverTerminalViewportPolicy(renderGrid.mobileViewportPolicy, surfaceID: renderGrid.surfaceID)
            MobileDebugLog.anchormux(
                "sync.render_grid_advisory source=\(source) surface=\(renderGrid.surfaceID) screen=\(renderGrid.activeScreen.rawValue) seq=\(renderGrid.stateSeq)"
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
        terminalActiveScreenBySurfaceID.removeValue(forKey: surfaceID)
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

    /// The Mac-pushed live font-size stream for a terminal surface.
    ///
    /// A mounted surface obtains this alongside ``terminalOutputStream(surfaceID:)``
    /// and applies each yielded point size to drive a live zoom (the grid reflows
    /// automatically). Ending iteration (or cancelling the consuming task)
    /// detaches the font continuation. Mirrors the output-stream lifecycle so the
    /// font signal never outlives the surface mount.
    /// - Parameter surfaceID: The terminal surface identifier.
    /// - Returns: An `AsyncStream` of absolute point sizes.
    public func terminalLiveFontStream(surfaceID: String) -> AsyncStream<Float32> {
        AsyncStream { continuation in
            let token = UUID()
            terminalLiveFontContinuationsBySurfaceID[surfaceID] = continuation
            terminalLiveFontTokensBySurfaceID[surfaceID] = token
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    // Only tear down if this exact stream is still registered; a
                    // same-surface remount may have replaced it before this ran.
                    guard self.terminalLiveFontTokensBySurfaceID[surfaceID] == token else { return }
                    self.terminalLiveFontContinuationsBySurfaceID.removeValue(forKey: surfaceID)
                    self.terminalLiveFontTokensBySurfaceID.removeValue(forKey: surfaceID)
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
            let remoteWorkspaceID = remoteWorkspaceID(for: workspaceID)
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.terminal.viewport",
                params: [
                    "workspace_id": remoteWorkspaceID.rawValue,
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
        let remoteWorkspaceID = remoteWorkspaceID(for: workspaceID)
        Task { @MainActor in
            let request = try? MobileCoreRPCClient.requestData(
                method: "mobile.terminal.viewport",
                params: [
                    "workspace_id": remoteWorkspaceID.rawValue,
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
        let remoteWorkspaceID = remoteWorkspaceID(for: workspaceID)
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
                        "workspace_id": remoteWorkspaceID.rawValue,
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
                    self.terminalActiveScreenBySurfaceID[surfaceID] = renderGrid.activeScreen
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

    private func handleTerminalSetFontEvent(_ event: MobileEventEnvelope) {
        guard
            let json = event.payloadJSON,
            let payload = try? MobileTerminalSetFontEvent.decode(json)
        else {
            return
        }
        let points = Float32(payload.fontSize)
        if let surfaceID = payload.surfaceID {
            terminalLiveFontContinuationsBySurfaceID[surfaceID]?.yield(points)
        } else if let targetWorkspaceID = payload.workspaceID {
            // Workspace-scoped: only mounted surfaces in that workspace, so
            // `set-font --workspace <id>` never resizes unrelated terminals.
            for (surfaceID, continuation) in terminalLiveFontContinuationsBySurfaceID
            where workspaceID(forTerminalID: surfaceID)?.rawValue == targetWorkspaceID {
                continuation.yield(points)
            }
        } else {
            // No explicit scope: drive every mounted surface, mirroring how the
            // Mac's own font-size change reflows all panes.
            for continuation in terminalLiveFontContinuationsBySurfaceID.values {
                continuation.yield(points)
            }
        }
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
        if terminalOutputTransport == .hybrid,
           terminalActiveScreenBySurfaceID[surfaceID] == .alternate {
            MobileDebugLog.anchormux("sync.bytes_suppressed_alt surface=\(surfaceID) bytes=\(bytes.count)")
            return
        }
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
    /// Bounded periodic refresh for the Computers screen's "keep it live while
    /// open" timer. The online dots come from the live presence subscription and
    /// secondary workspace lists come from their live read-only subscriptions —
    /// both push-driven — so this only re-reads the local paired-Mac rows (cheap
    /// SQLite) and re-fetches the FOREGROUND Mac's own list.
    ///
    /// It deliberately does NOT call `refreshWorkspaces()`: that fans out to
    /// `refreshSecondaryMacWorkspaces()`, which re-fetches every saved Mac and
    /// re-establishes/re-dials missing (including offline) subscriptions — exactly
    /// the every-10-seconds reconnect storm this screen must avoid. Recovering a
    /// dropped/offline Mac is driven by presence-push (a Mac re-announcing kicks a
    /// reconnect) and by the explicit pull-to-refresh / per-Mac Reconnect button.
    /// If a pull-to-refresh is already aggregating, ride its result rather than
    /// start a duplicate foreground fetch.
    public func refreshComputersScreen() async {
        await loadPairedMacs()
        guard connectionState == .connected, remoteClient != nil else { return }
        if let inFlight = pullToRefreshTask {
            await inFlight.value
            return
        }
        await reloadWorkspaceListFromMac()
    }

    /// Refresh the foreground Mac workspace list and re-aggregate secondary Macs.
    public func refreshWorkspaces() async {
        guard connectionState == .connected, remoteClient != nil else { return }
        if let inFlight = pullToRefreshTask {
            await inFlight.value
            return
        }
        let task = Task { @MainActor [weak self] in
            defer { self?.pullToRefreshTask = nil }
            await self?.reloadWorkspaceListFromMac()
            // Re-aggregate the other Macs too, so pull-to-refresh surfaces
            // workspaces created on a secondary Mac since the last fetch (the
            // read-only secondary list is a snapshot, not a live subscription).
            if self?.multiMacAggregationEnabled == true {
                await self?.refreshSecondaryMacWorkspaces()
            }
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
        mergeExistingWorkspaces: Bool = false,
        groupsAreAuthoritative: Bool = true
    ) {
        let remoteWorkspaces = remoteWorkspacesPreservingSnapshots(from: response)
        // Write the foreground Mac's per-Mac state; `workspaces` / `workspaceGroups`
        // recompute from the source of truth automatically (no explicit merge or
        // publish). Group sections are authoritative only on a full-list response:
        // a merge path or scoped attach response omits groups, so pass nil there
        // to leave the existing sections intact. Authoritative groups are passed
        // through the device-local collapse store before entering the per-Mac
        // source of truth, so derived groups keep this phone's collapse choices.
        let groups: [MobileWorkspaceGroupPreview]? =
            (mergeExistingWorkspaces || !groupsAreAuthoritative)
                ? nil
                : groupCollapseStore.apply(
                    to: response.groups.map { MobileWorkspaceGroupPreview(remote: $0) }
                )
        setForegroundWorkspaceState(
            workspaces: remoteWorkspaces, groups: groups, merge: mergeExistingWorkspaces)
        if preferActiveTicketTarget, selectActiveTicketTargetIfAvailable() {
            return
        }
        if let selectedWorkspaceID,
           workspaces.contains(where: { $0.id == selectedWorkspaceID }) {
            syncSelectedTerminalForWorkspace()
            return
        }
        let selectedRemoteID = response.workspaces.first(where: \.isSelected)
            .map { MobileWorkspacePreview.ID(rawValue: $0.id) }
        setSelectedWorkspaceID(
            selectedRemoteID.flatMap {
                rowWorkspaceID(forRemoteWorkspaceID: $0, macDeviceID: foregroundMacDeviceID)
            }
            ?? workspaces.first?.id
        )
        syncSelectedTerminalForWorkspace()
    }

    private func remoteWorkspacesPreservingSnapshots(
        from response: MobileSyncWorkspaceListResponse
    ) -> [MobileWorkspacePreview] {
        response.workspaces.map { remoteWorkspace in
            var workspace = MobileWorkspacePreview(remote: remoteWorkspace)
            // Tag every workspace with the Mac it came from, so the aggregated
            // multi-Mac list can group and filter by machine (P1 of the multi-Mac
            // work). Today there is one connected Mac, so all rows share its id.
            workspace.macDeviceID = activeTicket?.macDeviceID
            let foregroundMacID = foregroundMacDeviceID ?? activeTicket?.macDeviceID
            guard let existingWorkspace = workspaces.first(where: {
                workspaceMatchesRemoteID($0, remoteID: workspace.id, macDeviceID: foregroundMacID)
            }) else {
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
        guard let workspace = workspaces.first(where: {
            workspaceMatchesRemoteID($0, remoteID: ticketWorkspaceID, macDeviceID: foregroundMacDeviceID ?? activeTicket.macDeviceID)
        }) else {
            return false
        }
        setSelectedWorkspaceID(workspace.id)
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

    private func applyPreviewTicket(_ ticket: CmxAttachTicket, route: CmxAttachRoute) {
        let terminalID = ticket.terminalID ?? "attached-terminal"
        setForegroundWorkspaceState(
            workspaces: [
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
            ],
            groups: [],
            merge: false
        )
        selectedWorkspaceID = workspaces.first?.id
        selectedTerminalID = workspaces.first?.terminals.first?.id
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
