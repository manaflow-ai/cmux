public import CMUXMobileCore
public import CmuxAgentChat
internal import CmuxMobileDiagnostics
public import CmuxMobileBrowserStream
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
    /// Bound the peer fleet to five live sessions: one initial focus plus four
    /// warm peers. After the first focus handoff, the focused peer may also keep
    /// its control capability without consuming another transport session.
    static let maximumLiveMacConnectionCount = 5
    static let maximumWarmControlConnectionCount =
        maximumLiveMacConnectionCount - 1
    static let maximumSecondaryReconciliationConcurrency =
        maximumWarmControlConnectionCount

    static let maxTerminalReplayFailureRetries = 2
    static let maxTerminalReplayBarrierFollowUps = 1

    nonisolated enum TerminalOutputTransport: Equatable {
        case hybrid
        case renderGrid
        case rawBytes

        var eventTopics: [String] {
            switch self {
            case .hybrid:
                return [
                    "workspace.updated", "mobile.sync.delta",
                    "terminal.bytes", "terminal.render_grid", "terminal.set_font",
                    "notification.dismissed", "notification.badge", "notification.feed.changed",
                    "phone_push.status.changed", "caffeine.status.changed",
                    "browser.frame", "browser.state", "browser.closed", "browser.dialog", "browser.dialog.resolved",
                    "simulator.frame", "simulator.state", "simulator.closed",
                ]
            case .renderGrid:
                return [
                    "workspace.updated", "mobile.sync.delta",
                    "terminal.render_grid", "terminal.set_font",
                    "notification.dismissed", "notification.badge", "notification.feed.changed",
                    "phone_push.status.changed", "caffeine.status.changed",
                    "browser.frame", "browser.state", "browser.closed", "browser.dialog", "browser.dialog.resolved",
                    "simulator.frame", "simulator.state", "simulator.closed",
                ]
            case .rawBytes:
                return [
                    "workspace.updated", "mobile.sync.delta",
                    "terminal.bytes", "terminal.set_font",
                    "notification.dismissed", "notification.badge", "notification.feed.changed",
                    "phone_push.status.changed", "caffeine.status.changed",
                    "browser.frame", "browser.state", "browser.closed", "browser.dialog", "browser.dialog.resolved",
                    "simulator.frame", "simulator.state", "simulator.closed",
                ]
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
    /// Max seconds a stored-Mac reconnect may own its attempt flags before the
    /// onboarding connection scene exposes retry and QR fallback. The launch
    /// ``RestoringSessionView`` has its own shorter gate in ``CMUXMobileRootView``;
    /// this longer backstop covers scope lookup, backup refresh, and dialing.
    private let storedMacReconnectRestoringDeadlineSeconds: Double

    private static let terminalRenderGridCapability = "terminal.render_grid.v1"
    static let terminalVerifiedReplayCapability = "terminal.render_grid.verified_replay.v1"
    static let terminalScreenAnchorCapability = "terminal.render_grid.screen_anchor.v1"
    private static let terminalBytesCapability = "terminal.bytes.v1"
    static let browserStreamCapability = MobileBrowserStreamCapability.identifier
    static let browserStreamViewportCapability = MobileBrowserStreamCapability.viewportIdentifier
    static let browserStreamDialogCapability = MobileBrowserStreamCapability.dialogIdentifier
    static let browserStreamCreateCapability = MobileBrowserStreamCapability.createIdentifier
    static let simulatorStreamCapability = MobileSimulatorStreamCapability.current.identifier
    static let simulatorInputCapability = MobileSimulatorStreamCapability.current.inputIdentifier
    static let simulatorKeepaliveCapability = MobileSimulatorStreamCapability.current.keepaliveIdentifier
    static let simulatorStreamV2Capability = MobileSimulatorStreamCapability.current.streamV2Identifier
    static let terminalReplayCapability = "terminal.replay.v1"
    static let terminalInputOrderedCapability = "terminal.input.ordered.v1"
    static let maxTerminalReplayBarrierDroppedOutputBeforeFailOpen: UInt64 = 256
    static let terminalReplayViewportTransitionWatchdogTimeout: Duration = .seconds(3)
    static let workspaceActionsCapability = "workspace.actions.v1"
    static let workspaceChangesCapability = "workspace.changes.v1"
    static let workspaceMetadataCapability = "workspace.metadata.v1"
    static let workspaceReadStateCapability = "workspace.read_state.v1"
    static let workspaceCloseCapability = "workspace.close.v1"
    static let workspaceMoveCapability = "workspace.move.v1"
    static let workspaceMutationAccountAuthCapability = "workspace.mutations.account_auth.v1"
    static let workspaceGroupActionsCapability = "workspace.group_actions.v1"
    static let workspaceCreateInGroupCapability = "workspace.create_in_group.v1", workspaceGroupCreateCapability = "workspace.group_create.v1"
    static let taskCreateCapability = "workspace.task_create.v1"
    static let taskAttachmentCapability = "task.attachments.v1"
    static let taskModelsCapability = "task.models.v1"
    static let chatArtifactCapability = "chat.artifact.v1"
    static let chatArtifactSaveCapability = "chat.artifact.save.v1"
    static let chatArtifactGalleryCapability = "chat.artifact.gallery.v1"
    static let terminalArtifactCapability = "terminal.artifact.v1"
    static let panelArtifactCapability = "panel.artifact.v1"
    static let irohArtifactLaneCapability = "iroh.artifact_lane.v1"
    static let dogfoodFeedbackCapability = "dogfood.v1"
    static let workspaceGroupsCapability = "workspace.groups.v1"
    static let notificationFeedCapability = "notification.feed.v1"
    static let phonePushSettingsCapability = "phone_push.settings.v1"
    static let phonePushTestCapability = "phone_push.test.v1"
    static let caffeineControlCapability = "caffeine.control.v1"
    nonisolated private static let terminalOutputCapabilityTimeoutNanoseconds: UInt64 = 750_000_000
    /// How long the render-grid stream may stay silent (no event of any topic)
    /// before the liveness watchdog suspects the push subscription is dead and
    /// runs a bounded host probe; only repeated failed probes force the
    /// re-subscribe + replay (silence alone is the normal state of an idle
    /// terminal). Picked at the low end of the acceptable 8-12s window so a
    /// wedged stream recovers in a few seconds instead of the transport's ~85s
    /// timeout, while staying well above any normal inter-event gap on a busy
    /// shell.
    static let renderGridLivenessSilenceThreshold: TimeInterval = 9
    /// A single timed-out probe is ambiguous during Iroh path migration, app
    /// resume, or a short Mac stall. Require independent confirmation before
    /// replacing a session that may still be healthy.
    static let renderGridLivenessFailuresBeforeRecovery = 2
    /// Cadence of the liveness watchdog tick. It only reads a timestamp and
    /// compares against the threshold, so a short interval is cheap; it does not
    /// reschedule per received event (an actively-streaming connection just keeps
    /// failing the silence check because `lastTerminalEventAt` stays fresh).
    private static let renderGridLivenessCheckInterval: TimeInterval = 2.5
    /// An input ACK only reasserts the event subscription after this long
    /// without an event, preserving lost-registration recovery without adding a
    /// control-lane round trip to healthy continuous typing.
    static let terminalInputAckResubscribeSilenceThreshold: TimeInterval = 2
    /// Short background dwells usually preserve the event stream; beyond this,
    /// the liveness watchdog and normal foreground resync own catch-up.
    static let foregroundResyncShortBackgroundThreshold: TimeInterval = 30

    public private(set) var isSignedIn: Bool {
        didSet {
            guard oldValue != isSignedIn else { return }
            // Presence follows the session: subscribe while signed in, tear
            // down (and blank the map) the moment the user signs out so a
            // shared device never renders the previous account's devices.
            evaluatePresenceSubscription()
        }
    }
    public internal(set) var connectionState: MobileConnectionState {
        didSet {
            // Collapse the ~15 `connectionState = .disconnected/.connected` sites
            // into one analytics edge: emit at most one `ios_connection_lost` per
            // outage and one `ios_connection_recovered` per recovery. `didSet`
            // does not fire for the in-init assignment, so this only observes
            // real transitions. The throttle's `outageOpen` is the per-outage gate.
            guard oldValue != connectionState else { return }
            recordAppEvent(
                .connectionStateChanged,
                correlationID: foregroundMacDeviceID,
                count: connectionState == .connected ? 1 : 0
            )
            recordForegroundTransportSelected()
            if connectionState == .connected {
                restartTerminalLanesForMountedSurfaces()
                browserStreamEvents?.setBrowserStreamConnectionStatus(.connected)
                simulatorStreamStore?.setSimulatorStreamConnectionStatus(.connected)
                restartActiveMobileBrowserStreams()
                restartActiveMobileSimulatorStreams()
                scheduleWorkspaceChangesSummaryRefresh()
                #if DEBUG
                startLatencyProbeIfReady()
                startLatencyProbeAutoNavigationIfNeeded()
                #endif
            } else {
                deactivateAllTerminalLanes()
                startedMobileBrowserPanelIDs.removeAll()
                diagnosedMobileBrowserFramePanelIDs.removeAll()
                diagnosedMobileBrowserStatePanelIDs.removeAll()
                diagnosedMobileBrowserFrameAckFailurePanelIDs.removeAll()
                startedMobileSimulatorPanelIDs.removeAll()
                cancelMobileSimulatorStreamOperations()
                browserStreamEvents?.setBrowserStreamConnectionStatus(
                    macConnectionStatus == .reconnecting ? .reconnecting : .disconnected
                )
                simulatorStreamStore?.setSimulatorStreamConnectionStatus(
                    macConnectionStatus == .reconnecting ? .reconnecting : .disconnected
                )
                resetWorkspaceChangesState()
                #if DEBUG
                cancelLatencyProbe()
                #endif
            }
            // Intentional teardown (sign-out, hide, switch) must not look like
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
    public internal(set) var macConnectionStatus: MobileMacConnectionStatus {
        didSet {
            guard oldValue != macConnectionStatus else { return }
            recomputeNotificationFeedItems()
        }
    }
    public internal(set) var connectedHostName: String
    public private(set) var connectionError: String?
    /// Actionable next-step line shown beneath ``connectionError`` (for example
    /// "Check that both devices are on the same Tailscale"). Set and cleared
    /// together with the error by the pairing-failure classifier sink.
    public private(set) var connectionErrorGuidance: String?
    /// A warning that must be accepted before pairing continues, currently used
    /// for Mac/iPhone app-version skew.
    public private(set) var pairingVersionWarning: String?
    public internal(set) var activeTicket: CmxAttachTicket?
    public internal(set) var activeRoute: CmxAttachRoute? {
        didSet {
            guard oldValue != activeRoute, connectionState == .connected else { return }
            recordForegroundTransportSelected()
            restartTerminalLanesForMountedSurfaces()
        }
    }

    /// Records which transport actually carries the foreground connection, so
    /// a shared report states Iroh vs Tailscale usage explicitly instead of
    /// leaving it implied by whichever dial events survived the ring.
    ///
    /// Hooked to both the connected transition and active-route changes: some
    /// connect flows pin the route before flipping the state and others after,
    /// and a mid-connection promotion swaps the route with no state change.
    private func recordForegroundTransportSelected() {
        guard connectionState == .connected, let route = activeRoute else { return }
        recordAppEvent(
            .foregroundTransportSelected,
            correlationID: foregroundMacDeviceID,
            count: DiagnosticTransportKind(route.kind).rawValue
        )
    }
    /// Authenticated Mac app-instance identity for the foreground connection.
    /// `nil` only for a fresh/legacy host that has not reported one.
    var activeMacInstanceTag: String?

    /// True while the latest stored-Mac reconnect attempt is active.
    ///
    /// Set before scope resolution, backup refresh, and paired-Mac lookup so
    /// onboarding can present one bounded searching state for the complete attempt.
    /// The root restoring gate separately treats
    /// ``didFinishStoredMacReconnectAttempt`` as sticky for the current account,
    /// so later background retries do not replace the disconnected workspace UI.
    public internal(set) var isReconnectingStoredMac: Bool = false

    /// True once the first launch reconnect attempt has resolved.
    ///
    /// A failed or offline reconnect sets this so the root scene falls through to
    /// the disconnected/add-device view instead of spinning on
    /// ``RestoringSessionView`` forever.
    public internal(set) var didFinishStoredMacReconnectAttempt: Bool = false

    /// Persisted hint that this device has previously paired a Mac.
    ///
    /// Read synchronously at init from the injected `UserDefaults` so the very
    /// first rendered frame can show ``RestoringSessionView`` for a returning user
    /// before the async paired-Mac read runs. Writes persist through to the same
    /// defaults via the property's `didSet`.
    public internal(set) var hasKnownPairedMac: Bool {
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
    /// sign-out, hide) each claim a generation; only the current generation may
    /// resolve the restoring-gate flags, so a superseded older attempt can't clear
    /// the gate while a newer reconnect is still in progress.
    var storedMacReconnectGeneration = 0
    /// Set when a connection-method change arrives during a reconnect. The
    /// latest forced retry starts as soon as the current attempt settles.
    var pendingForcedStoredMacReconnect = false
    var automaticReconnectBackoffOwner = MobileAutomaticReconnectBackoffOwner()
    var automaticReconnectRetryTask: Task<Void, Never>?
    var automaticReconnectRetryAccountID: String?
    var automaticReconnectRetryAt: Date?
    /// Hard ceiling on one recovery-owner attempt (drain + dial + validation).
    /// Every inner phase carries its own deadline; this exists so an await
    /// that escapes them (a wedged FFI close, a continuation that never
    /// resumes) degrades into a bounded failure with a scheduled retry
    /// instead of an owner that silently coalesces every later trigger.
    var connectionRecoveryAttemptDeadlineTask: Task<Void, Never>?
    var lastPresenceReconnectEvidence: (
        scope: MobileShellScopeSnapshot,
        instances: [MobilePresenceReconnectEvidence]
    )?
    var presencePushRecoveryThrottle = MobilePresencePushRecoveryThrottle()
    /// Whether the current attach ticket has a non-empty auth token and has not expired.
    public var hasActiveUnexpiredAttachTicket: Bool {
        guard let activeTicket,
              activeTicket.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        return attachTicketIsUnexpired(activeTicket, now: runtime?.now() ?? Date())
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
    var workspacesByMac: [MacPairingKey: MacWorkspaceState] = [:] {
        didSet {
            recomputeDerivedWorkspaceState()
            // Workspace title/progress events are frequent. Reprojecting and
            // sorting the retained feed on every one would put an unrelated
            // O(feed log) pass on that hot path. Feed rows only depend on
            // this dictionary's per-Mac reachability, so update them when that
            // smaller projection actually changes.
            let oldStatuses = oldValue.mapValues(\.status)
            let newStatuses = workspacesByMac.mapValues(\.status)
            if oldStatuses != newStatuses {
                recomputeNotificationFeedItems()
            }
        }
    }
    let workspaceAggregation = MobileWorkspaceAggregation(); var stableMacColorSlots: [String: Int] = [:]  // see MobileShellComposite+MacSwitchState.swift
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
    /// The immutable, reverse-chronological notification feed aggregated across Macs.
    public internal(set) var notificationFeedItems: [MobileNotificationFeedItem] = [] {
        didSet {
            notificationFeedUnreadCount = notificationFeedItems.lazy.filter { !$0.isRead }.count
        }
    }
    /// The feed's current loading and capability state.
    public internal(set) var notificationFeedStatus: MobileNotificationFeedStatus = .idle
    /// The number of currently retained unread notifications across all Macs.
    public private(set) var notificationFeedUnreadCount: Int = 0
    /// The group sections the UI renders. A materialized derivation of every
    /// entry in ``workspacesByMac``. Each group's `isCollapsed` reflects this
    /// device's choice (see ``groupCollapseStore``), not the Mac's live value.
    public internal(set) var workspaceGroups: [MobileWorkspaceGroupPreview] = []

    /// The distinct per-pairing color index map (the SAME assignment the aggregated
    /// workspace avatars use), so the Computers screen can color each Mac's row to
    /// match its workspaces. Keyed by exact pairing id, including build tag.
    public var machineColorIndex: [String: Int] {
        stableMacColorSlots
    }

    public var macConnectionStatuses: [String: MobileMacConnectionStatus] {
        var result = workspacesByMac.reduce(into: [String: MobileMacConnectionStatus]()) { statuses, entry in
            guard entry.key != .anonymousForeground else { return }
            statuses[entry.key.pairingID] = entry.value.status
        }
        for (representativeID, aliases) in pairedMacAliasIDsByRepresentativeID {
            if result[representativeID] != nil { continue }
            let representativeTag = MobilePairedMac.pairingIdentity(
                from: representativeID
            ).instanceTag
            let aliasStatuses = aliases.compactMap {
                result[MobilePairedMac.pairingID(
                    macDeviceID: $0,
                    instanceTag: representativeTag
                )]
            }
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
    /// Device-local sort preference for the aggregated All Computers list
    /// (mode + user computer order). `@ObservationIgnored`: views read the
    /// observable ``workspaceSortMode`` / ``workspaceComputerPriority``
    /// mirrors below; this store only persists. Injected so tests/previews can
    /// pass a suite-scoped `UserDefaults`.
    @ObservationIgnored var workspaceSortStore: MobileWorkspaceSortStore
    /// Observable mirror of ``MobileWorkspaceSortStore/mode``. Change through
    /// ``setWorkspaceSortMode(_:)`` so persistence and the derived list stay
    /// in step.
    public internal(set) var workspaceSortMode: MobileWorkspaceSortMode = .automatic
    /// Observable mirror of ``MobileWorkspaceSortStore/computerPriority``.
    /// Change through ``setWorkspaceComputerPriority(_:)``.
    public internal(set) var workspaceComputerPriority: [String] = []
    /// Device-local task templates used by the iOS task composer.
    @ObservationIgnored public let taskTemplateStore: (any MobileTaskTemplateStoring)?
    /// Over-the-air fallback used when the selected Mac's agent cannot list models.
    @ObservationIgnored let taskModelCatalogClient: MobileTaskModelCatalogClient
    /// Mac/provider model responses observed by the task composer.
    var taskModelCache: [MobileTaskModelCacheKey: MobileTaskModelCacheEntry] = [:]
    /// The connected Mac's `mobile.host.status` capabilities. Feature gates are
    /// computed from this set so version-skew checks cannot drift from the raw
    /// host payload.
    public internal(set) var supportedHostCapabilities: Set<String> = [] {
        didSet {
            guard oldValue != supportedHostCapabilities else { return }
            recordAppEvent(
                .capabilitySnapshotReceived,
                correlationID: foregroundMacDeviceID,
                count: supportedHostCapabilities.count
            )
            if workspaceChangesCapable {
                scheduleWorkspaceChangesSummaryRefresh()
            } else {
                resetWorkspaceChangesState()
            }
        }
    }
    /// Authenticated phone-forwarding readiness from the focused Mac. `nil`
    /// means no attached Mac has proved same-account ownership and exposed the
    /// independent Mac privacy gate.
    public internal(set) var phonePushMacStatus: MobileHostPhonePushStatus?
    /// The connected Mac's current cmux-owned keep-awake state. `nil` means
    /// the state has not been read or the current Mac is unavailable.
    public internal(set) var caffeineStatus: MobileCaffeineStatus?
    /// Whether a caffeine RPC mutation is currently awaiting the Mac.
    public internal(set) var isCaffeineMutationInFlight = false
    @ObservationIgnored var caffeineMutationID: UUID?
    /// Monotonic fence for authoritative caffeine snapshots. It survives
    /// connection resets so an older reconciliation cannot match newer state.
    @ObservationIgnored var caffeineStatusRevision: UInt64 = 0

    /// Whether the authenticated Mac supports changing its independent phone
    /// forwarding privacy gates from iOS.
    public var supportsPhonePushSettings: Bool {
        supportedHostCapabilities.contains(Self.phonePushSettingsCapability)
    }

    /// Whether the authenticated Mac can enqueue a correlated test alert.
    public var supportsPhonePushTest: Bool {
        supportedHostCapabilities.contains(Self.phonePushTestCapability)
    }

    /// Whether the authenticated Mac supports the Keep Mac Awake RPC.
    public var supportsCaffeineControl: Bool {
        supportedHostCapabilities.contains(Self.caffeineControlCapability)
    }
    /// Published workspace-list chip snapshots keyed by Mac-local workspace id.
    ///
    /// Like ``workspaces``, this is a materialized immutable-value surface on the
    /// `@Observable` composite; list rows receive copied values, never the store.
    public private(set) var workspaceChangeChipsByWorkspaceID: [String: MobileWorkspaceChangesChip] = [:]
    /// Device-local persistence for the one-time workspace-changes hint.
    @ObservationIgnored var workspaceChangesHintDismissalStore: MobileWorkspaceChangesHintDismissalStore

    func setWorkspaceChangeChipsByWorkspaceID(
        _ chips: [String: MobileWorkspaceChangesChip]
    ) {
        workspaceChangeChipsByWorkspaceID = chips
    }

    /// Separate app-lifetime browser event sink; never stored in workspace preview state.
    @ObservationIgnored let browserStreamEvents: (any BrowserStreamEventReceiving)?
    /// Separate app-lifetime simulator stream state; never stored in workspace preview state.
    @ObservationIgnored let simulatorStreamStore: MobileSimulatorStreamStore?
    @ObservationIgnored let mobileBrowserStreamLifecycle = MobileBrowserStreamLifecycleCoordinator()
    @ObservationIgnored var startedMobileBrowserPanelIDs: Set<String> = []
    /// Panels whose first frame in the current subscription was logged. Frame
    /// payloads are intentionally sampled at this boundary so a busy page
    /// cannot evict every other diagnostic from the bounded ring.
    @ObservationIgnored var diagnosedMobileBrowserFramePanelIDs: Set<String> = []
    /// Panels whose first decoded state in the current subscription was logged.
    /// State pushes may repeat during navigation, so this follows the same
    /// per-subscription sampling policy as frames.
    @ObservationIgnored var diagnosedMobileBrowserStatePanelIDs: Set<String> = []
    /// Panels with an outstanding frame-ack failure. One event opens an outage;
    /// a later successful acknowledgement clears it so a distinct outage can
    /// be recorded without logging at frame cadence.
    @ObservationIgnored var diagnosedMobileBrowserFrameAckFailurePanelIDs: Set<String> = []
    /// Surfaces whose first output in the current mount was logged. Sampling
    /// proves that output reached each feature path without letting a busy
    /// terminal evict the rest of the bounded diagnostic timeline.
    @ObservationIgnored var diagnosedTerminalOutputSurfaceIDs: Set<String> = []
    @ObservationIgnored var startedMobileSimulatorPanelIDs: Set<String> = []
    /// Per-panel simulator stream operation chains. Each start/stop awaits the
    /// panel's previous operation, so a background stop and a foreground
    /// restart can never interleave against the Mac's single-controller
    /// ownership. Entries self-remove when their chain drains.
    @ObservationIgnored var mobileSimulatorStreamOperationsByPanel: [String: Task<Void, Never>] = [:]
    /// Clock behind the simulator stream staleness watchdog; injectable so
    /// tests drive the threshold deterministically.
    @ObservationIgnored let simulatorStreamStalenessClock: any Clock<Duration>
    /// Fires when an active simulator stream produces no frame or keepalive
    /// events for a full threshold, i.e. three missed Mac keepalives. Armed
    /// only against Macs advertising `simulator.keepalive.v1`, so a static
    /// screen on a keepalive-less host can never read as stale.
    @ObservationIgnored private(set) lazy var simulatorStreamStalenessMonitor =
        MobileSimulatorStreamStalenessMonitor(
            clock: simulatorStreamStalenessClock,
            threshold: Self.mobileSimulatorStreamStaleThreshold
        ) { [weak self] panelID in
            self?.handleStaleMobileSimulatorStream(panelID: panelID)
        }
    static let mobileSimulatorStreamStaleThreshold: Duration = .seconds(15)
    @ObservationIgnored var terminalThemeState = MobileTerminalThemeState()
    /// The selected surface's effective theme and iOS chrome source of truth.
    public internal(set) var activeTerminalTheme: TerminalTheme = .monokai
    /// Raw Ghostty defaults, kept separate so OSC resets exclude dynamic colors.
    public internal(set) var activeTerminalConfigTheme: TerminalTheme = .monokai
    /// Bumped when the selected effective theme changes so mounted chrome repaints without remounting.
    public internal(set) var terminalThemeGeneration: UInt64 = 0
    /// Bumped only when the selected surface's raw Ghostty defaults change.
    public internal(set) var terminalConfigThemeGeneration: UInt64 = 0
    /// A truthful released-Mac-update recommendation for the connected host.
    public internal(set) var macUpdateHint: MobileMacUpdateHint?
    @ObservationIgnored var macUpdateHintSessionState = MacUpdateHintSessionState()
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
            if !isLoadingDraft,
               !terminalInputText.isEmpty,
               terminalInputText != oldValue,
               let terminalID = selectedTerminalID?.rawValue {
                clearSettledTerminalSendStatus(forTerminalID: terminalID)
            }
            if !isLoadingDraft,
               terminalInputText.isEmpty != oldValue.isEmpty {
                recordAppEvent(
                    .terminalDraftStateChanged,
                    correlationID: selectedTerminalID?.rawValue,
                    count: terminalInputText.isEmpty ? 0 : 1
                )
            }
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
    /// The surface input session owns first-responder commands; SwiftUI `@FocusState`
    /// mirrors their result. When the surface needs the field re-focused without
    /// re-presenting the composer, it bumps this token through
    /// ``presentAndFocusComposer()``. ``TerminalComposerView`` consumes the keyed
    /// intent and forwards it to that session owner.
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
    /// The last user-visible send settlement for each terminal. Unlike the
    /// re-entrancy flags above, this is observed by both the composer button and
    /// terminal command status pill.
    private var terminalSendStatusesByTerminalID: [String: MobileTerminalSendStatus] = [:]
    /// Latest operation identity per terminal. A late result from an older send
    /// cannot overwrite the state of a newer retry.
    @ObservationIgnored private var terminalSendOperationIDsByTerminalID: [String: UUID] = [:]
    /// Raw-command operations are tracked separately so a focus/connection
    /// pipeline clear can settle only those sends without disturbing an
    /// independently in-flight composer paste pinned to the same terminal.
    @ObservationIgnored private var rawTerminalSendOperationIDsByTerminalID: [String: UUID] = [:]
    /// Pending image attachments per terminal, keyed by terminal id so switching
    /// terminals keeps each draft's own attachments (mirroring how the text draft
    /// is keyed). Observed so the composer's chip row re-renders on add/remove.
    /// Sent in order on the next submit and then cleared for that terminal.
    private var pendingAttachmentsByTerminalID: [String: [MobilePendingAttachment]] = [:]

    public func terminalSendStatus(forTerminalID terminalID: String) -> MobileTerminalSendStatus {
        terminalSendStatusesByTerminalID[terminalID] ?? .idle
    }

    @discardableResult
    private func beginTerminalSend(forTerminalID terminalID: String) -> UUID {
        let operationID = UUID()
        terminalSendOperationIDsByTerminalID[terminalID] = operationID
        terminalSendStatusesByTerminalID[terminalID] = .sending
        recordAppEvent(
            .terminalInputSubmitted,
            correlationID: terminalID
        )
        return operationID
    }

    private func finishTerminalSend(
        _ operationID: UUID?,
        forTerminalID terminalID: String,
        succeeded: Bool
    ) {
        guard let operationID,
              terminalSendOperationIDsByTerminalID[terminalID] == operationID else { return }
        terminalSendStatusesByTerminalID[terminalID] = succeeded ? .sent : .failed
        recordAppEvent(
            succeeded ? .terminalInputAcknowledged : .terminalInputDropped,
            correlationID: terminalID,
            failure: succeeded ? nil : .unknown
        )
    }

    private func clearSettledTerminalSendStatus(forTerminalID terminalID: String) {
        guard terminalSendStatusesByTerminalID[terminalID] != .sending else { return }
        terminalSendStatusesByTerminalID[terminalID] = nil
        terminalSendOperationIDsByTerminalID[terminalID] = nil
    }

    private func finishRawTerminalSend(
        _ operationID: UUID?,
        forTerminalID terminalID: String,
        succeeded: Bool
    ) {
        guard let operationID,
              rawTerminalSendOperationIDsByTerminalID[terminalID] == operationID else { return }
        rawTerminalSendOperationIDsByTerminalID[terminalID] = nil
        finishTerminalSend(
            operationID,
            forTerminalID: terminalID,
            succeeded: succeeded
        )
    }

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
    /// Per-file byte cap for one staged FILE attachment, matching the
    /// task-attachment upload limit its send-time transport enforces on the
    /// Mac side. Larger than the per-image cap because files are not
    /// re-encoded down; the per-terminal and global byte budgets still bound
    /// the aggregate.
    public nonisolated static let maxPendingAttachmentFileBytes =
        TaskComposerAttachment.maximumFileBytes
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
    /// session. Async paths that can suspend across an auth boundary capture it
    /// before leaving the main actor and re-check it just before mutating the store:
    /// a sign-out bumps the token, so stale continuations are dropped instead of
    /// writing the previous user's state under ids the next account may reuse. Not
    /// observed: it gates async hand-backs, not view state.
    @ObservationIgnored var signInGeneration = 0
    public var selectedWorkspaceID: MobileWorkspacePreview.ID? {
        didSet {
            if selectedWorkspaceID != oldValue {
                selectedMacSurfaceID = nil
            }
            syncSelectedTerminalForWorkspace()
        }
    }
    /// The Mac surface shown in the workspace detail instead of the selected
    /// terminal, or nil when the terminal is visible. Independent of
    /// ``selectedTerminalID`` (so dismissing the surface returns to the same
    /// terminal and composer draft) and cleared when the workspace changes.
    public var selectedMacSurfaceID: MobileSurfacePreview.ID?
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
            if let selectedTerminalID {
                recordAppEvent(
                    .surfaceFocused,
                    correlationID: selectedTerminalID.rawValue
                )
            }
            swapDraft(from: draftedOutgoingTerminalID, outgoingText: draftedOutgoingText, to: selectedTerminalID)
            draftedOutgoingTerminalID = nil
            draftedOutgoingText = ""
            applySelectedTerminalTheme()
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
    /// The user's connection-method choice. The shipping app always injects
    /// this at the composition root (`AppCompositionRoot` holds it
    /// non-optional), so a user-selected Tailscale Only choice can never be
    /// dropped at runtime. `nil` exists only for DEBUG previews, the
    /// hide-computers verifier, and unit-test fixtures, which have no user
    /// preference and behave like the default automatic method.
    let connectionMethodStore: MobileConnectionMethodStore?
    /// Single compatibility authority shared by registry, persistence, and live connections.
    let buildCompatibilityPolicy: MobileMacBuildCompatibilityPolicy?
    /// Single physical-Mac identity authority shared by every connection role.
    let macInstanceTagAuthority: MobileMacInstanceTagAuthority
    private let pairedMacRestoreBoundary: PairedMacRestoreBoundary?
    /// Best-effort, team-scoped lookup of fresher attach routes from the device
    /// registry. Optional and failure-tolerant: when `nil` or unreachable,
    /// reconnect uses the locally persisted paired-Mac routes, so pairing
    /// survives the cloud registry being down.
    let deviceRegistry: (any DeviceRegistryRefreshing)?
    /// Live same-account Iroh discovery. This is distinct from route refresh so
    /// only a current broker response may initiate a first pairing.
    let personalIrohDiscovery: (any MobileIrohMacDiscovering)?
    /// Revokes a hidden computer's account bindings when the user forgets it.
    /// Optional so tests and non-iOS hosts run without the transport graph; when
    /// `nil`, the Forget action is a no-op and the row stays put.
    let personalIrohForget: (any MobileIrohMacForgetting)?
    /// Live presence subscription (the `workers/presence` Durable Object edge).
    /// Optional and failure-tolerant like the registry: when `nil` or down, the
    /// device tree simply keeps its registry "last seen" hints.
    private let presence: (any PresenceSubscribing)?
    let identityProvider: (any MobileIdentityProviding)?
    let teamIDProvider: @Sendable () async -> String?
    let reachability: any ReachabilityProviding
    // Internal (not private): used by the dismiss-sync extension file.
    let deliveredNotificationClearer: any DeliveredNotificationClearing
    /// Durable outbox for phone→Mac dismissals.
    let pendingDismissQueue: PendingNotificationDismissQueue
    private let pairingHintDefaults: UserDefaults
    private let multiMacAggregationDefaults: UserDefaults
    let hiddenMacStore: any PairedMacHiddenStoring
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
    let analytics: any AnalyticsEmitting
    let connectAttemptRegistry = MobileRPCConnectAttemptRegistry()
    /// The pre-authentication client owned by the current foreground connect.
    /// Tracking it separately from `remoteClient` lets a newer connect retire
    /// the exact candidate that still owns a physical-route lease.
    private var connectionAttemptClient: MobileCoreRPCClient?
    /// Owns asynchronous transport cleanup until each retired client confirms
    /// it transferred its route lease to the bounded registry cleanup path.
    private var clientDisconnectTasks: [UUID: Task<Void, Never>] = [:]
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
    /// Whether the pending version-warning URL came from an explicit in-app
    /// pairing-code entry (scanner or paste), preserved across the warning
    /// round-trip so acceptance keeps the same Tailscale authorization power.
    private var pendingPairingVersionWarningWasUserEntered = false

    /// The structured diagnostic log, injected from the app composition root.
    ///
    /// Recording is non-blocking and `nonisolated`, so the connect/pair, liveness,
    /// and seq/byte-gap seams below dual-emit a compact ``DiagnosticEvent``
    /// alongside their existing ``MobileDebugLog/anchormux(_:)`` string line.
    /// `nil` in previews/tests that do not exercise the round-trip. Exposed
    /// `public` so the DEV feedback-submit affordance can ``DiagnosticLog/export()``
    /// it.
    public let diagnosticLog: DiagnosticLog?
    package var remoteClient: MobileCoreRPCClient? {
        didSet {
            if remoteClient == nil {
                stopTerminalRefreshPolling()
                cancelRemoteOperationTasks()
                resetTerminalOutputTracking()
            }
        }
    }
    /// Whether legacy connected-but-clientless shells use local iOS workspace creation.
    public var usesLocalWorkspaceCreationFallback: Bool {
        remoteClient == nil && connectionState == .connected
    }
    /// `remoteClient` narrowed for `MobileShellComposite+AgentChat.swift`.
    var remoteClientForAgentChat: MobileCoreRPCClient? { remoteClient }
    var terminalEventListenerTask: Task<Void, Never>?
    private var terminalEventListenerID: UUID?
    /// Recovers the Mac's identity post-handshake for tickets that arrived
    /// without one (the minimal v2 pairing QR). Owned separately from the
    /// short capability probe; see ``scheduleHostIdentityAdoptionIfNeeded(client:)``.
    /// Cancelled on disconnect via ``cancelRemoteOperationTasks()``.
    private var hostIdentityAdoptionTask: Task<Void, Never>?
    /// Tail of the serialized paired-Mac store write chain; see
    /// ``performSerializedPairedMacWrite(ifStillCurrent:_:)``.
    private var pairedMacWriteChain: Task<Void, Never>?
    var pushedRouteSyncTask: Task<Void, Never>?
    var pushedRouteSyncOperationID: UUID?
    var pushedRouteSyncScope: MobileShellScopeSnapshot?
    var pushedRouteSyncPendingInstances: [String: PresenceInstance] = [:]
    private var secondaryAggregationAfterPushedRoutesTask:
        Task<Void, Never>?
    private var secondaryAggregationAfterPushedRoutesOperationID: UUID?
    private var secondaryAggregationAfterPushedRoutesScope:
        MobileShellScopeSnapshot?
    private var secondaryAggregationAfterPushedRoutesMacIDs: Set<String> = []
    private var secondaryAggregationAfterPushedRoutesNeedsFullRefresh = false
    var registryRouteRefreshTask: Task<Void, Never>?
    /// The in-flight `mobile.events.subscribe` (reason `start`) ack for the
    /// current listener generation. It runs concurrently with the consumer
    /// loop (the ack is a server-side enable handshake, not a delivery
    /// precondition: a prior generation's server subscription keeps pushing
    /// across re-subscribes) so events arriving during the round-trip are
    /// consumed, not buffered invisibly behind the await.
    private var terminalSubscriptionStartTask: Task<Void, Never>?
    /// Subscription success is the final validation edge for a replacement
    /// connection or listener. This snapshot closes the race where an old
    /// acknowledgement arrives after a newer listener has taken ownership.
    var lastSuccessfulTerminalSubscription: MobileTerminalSubscriptionValidation?
    /// Focused clients whose terminal subscribe/reassert operations are fenced
    /// while their final unsubscribe is prepared. Per-client tokens prevent an
    /// older A→B cleanup from clearing a newer A→B handoff after rapid reversal.
    /// The stored handoff retains its client, so an entry can never name a
    /// deallocated address that a later client could reuse.
    var terminalSubscriptionHandoffFences:
        [ObjectIdentifier: PendingTerminalSubscriptionHandoff] = [:]
    /// Focus-transition maintenance (session-purpose sync, demoted-control
    /// activation) keyed by the client it maintains. A newer transition for the
    /// same client cancels the older instance, so a rapid A→B→A reversal cannot
    /// run overlapping purpose loops; sign-out tears all of them down. The task
    /// closure retains its client, so an entry never outlives that identity.
    private var focusTransitionMaintenanceTasks:
        [ObjectIdentifier: (token: UUID, task: Task<Void, Never>)] = [:]
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
    // only tears down + re-subscribes + replays after repeated probe failures
    // with no intervening event or successful probe.
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
    private var renderGridLivenessConsecutiveProbeFailures = 0
    var lastTerminalEventAt: Date?
    @ObservationIgnored var terminalInputAckResubscribeRetryTask: Task<Void, Never>?
    @ObservationIgnored var terminalInputAckResubscribeRetryTaskID: UUID?
    @ObservationIgnored var terminalInputAckResubscribeRetrySurfaceID: String?
    /// Injected clock for the bounded ACK freshness-window follow-up.
    @ObservationIgnored let terminalInputAckResubscribeClock: any Clock<Duration>
    var lastBackgroundedAt: Date?
    var foregroundResumeEpoch: UInt64 = 0
    private var terminalSubscriptionRefreshTask: Task<Void, Never>?
    var notificationReconcileTask: Task<Void, Never>?
    var createWorkspaceTask: Task<Result<Void, MobileWorkspaceMutationFailure>, Never>?
    var createWorkspaceTaskGroupID: MobileWorkspaceGroupPreview.ID?
    var createWorkspaceTaskSpec: MobileWorkspaceCreateSpec?
    private var createTerminalTask: Task<Void, Never>?
    var workspaceListRefreshTask: Task<Bool, Never>?
    private var workspaceListRefreshOperationID: UUID?
    /// Advances before every foreground `workspace.updated` refetch. Promotion
    /// rejects its own handoff snapshot when a newer event races that fetch.
    var workspaceListEventGeneration: UInt64 = 0
    /// Advances whenever the shared foreground list application seam runs,
    /// including mobile state-sync snapshots and deltas.
    var foregroundWorkspaceStateRevision: UInt64 = 0
    @ObservationIgnored var workspaceChangesSummaryDebounceTask: Task<Void, Never>?
    @ObservationIgnored var workspaceChangesSummaryDebounceTaskID: UUID?
    @ObservationIgnored var workspaceChangesSummaryFetchTask: Task<Void, Never>?
    @ObservationIgnored var workspaceChangesSummaryFetchTaskID: UUID?
    @ObservationIgnored var workspaceChangesSummaryTrailingTask: Task<Void, Never>?
    @ObservationIgnored var workspaceChangesSummaryTrailingTaskID: UUID?
    @ObservationIgnored var workspaceChangesSummaryTrailingDeadline: Date?
    @ObservationIgnored var workspaceChangesSummaryTrailingExpiryByWorkspaceID: [String: Date] = [:]
    @ObservationIgnored var workspaceChangesSummaryRefreshSchedulePolicy =
        WorkspaceChangesSummaryRefreshSchedulePolicy()
    @ObservationIgnored var workspaceChangesSummaryFetchedAtByWorkspaceID: [String: Date] = [:]
    @ObservationIgnored let workspaceChangesSummaryFetchPolicy = WorkspaceChangesSummaryFetchPolicy()
    /// Wall time of the last EVENT-driven summary schedule (never trailing
    /// passes). Trailing refreshes only re-arm while events are recent, so an
    /// idle phone cannot hold the Mac in a perpetual 15-second git poll loop.
    @ObservationIgnored var workspaceChangesSummaryLastEventAt: Date?
    /// Injected clock for the summary debounce and trailing-expiry sleeps so
    /// tests can drive the 250 ms window and expiry firing deterministically.
    @ObservationIgnored let workspaceChangesSchedulingClock: any Clock<Duration>
    /// Injected clock for control-pool keepalives and bounded reconnect backoff.
    @ObservationIgnored let controlPlaneSchedulingClock: any Clock<Duration>
    /// Whole-operation deadline for draining subscription reassertions during
    /// a user-visible role handoff.
    @ObservationIgnored let connectionHandoffDrainTimeoutNanoseconds: UInt64
    /// Mobile state sync v2 (docs/mobile-state-sync-v2.md): full-record mirror
    /// of the foreground Mac's workspace/group collections plus its cursor.
    /// Never reset on reconnect; the epoch in every frame invalidates stale
    /// cursors, so a same-Mac resubscribe catches up with one small delta.
    let stateSyncMirror = MobileStateSyncMirror()
    /// The client that earned state-sync authority by a successful
    /// `mobile.sync.fetch`. v2 is active only while this identity matches the
    /// CURRENT `remoteClient`, so replacing the client (secondary-to-
    /// foreground promotion, reconnect) implicitly demotes to legacy until
    /// the new client's own negotiation completes — no explicit hook needed,
    /// and a stale client's deltas or fallbacks can never act on its
    /// successor's authority.
    var stateSyncAuthorityClientID: ObjectIdentifier?
    /// Whether state sync v2 owns the list for the CURRENT client. While
    /// true, `workspace.updated` no longer schedules full-list refetches;
    /// `mobile.sync.delta` events own the list.
    var stateSyncActive: Bool {
        guard let stateSyncAuthorityClientID, let remoteClient else { return false }
        return stateSyncAuthorityClientID == ObjectIdentifier(remoteClient)
    }
    /// Identity of the client the in-flight fetch runner serves; demand for
    /// the same client coalesces onto the runner instead of cancelling it.
    var stateSyncFetchClientID: ObjectIdentifier?
    /// Set while a runner is in flight to request one trailing sweep after it
    /// settles (a delta arrived that the current fetch's snapshot may miss).
    var stateSyncFetchFollowUpRequested = false
    /// Single-flight handle for negotiation and gap-repair fetches, restart-on-
    /// newest like ``workspaceListRefreshTask``. Bool payload = fetch applied.
    var stateSyncFetchTask: Task<Bool, Never>?
    /// Identifies the fetch generation that owns ``stateSyncFetchTask``, so a
    /// cancelled predecessor's deferred cleanup cannot clear its replacement.
    var stateSyncFetchGeneration = UUID()
    /// Number of deadline-abandoned reconnect dials that have not yet
    /// resolved. Bounds automatic retry scheduling (see
    /// ``registerAbandonedReconnectDial(_:)``).
    var abandonedReconnectDialCount = 0
    /// The user pull-to-refresh round-trip, kept on its own handle so the
    /// event-driven ``workspaceListRefreshTask`` cancel/restart can never truncate
    /// the spinner the pull is awaiting. Rapid pulls coalesce onto this single task.
    private var pullToRefreshTask: Task<Void, Never>?
    /// Foreground post-mutation list refreshes, coalesced separately from
    /// pull-to-refresh so batched row actions do not fan out legacy list RPCs.
    private var foregroundWorkspaceMutationRefreshTask: Task<Void, Never>?
    /// Set when a later foreground mutation lands while the post-mutation
    /// refresh is already in flight. The runner drains one trailing refresh so
    /// the latest mutation is reconciled even if the first fetch captured the
    /// pre-mutation state.
    private var foregroundWorkspaceMutationRefreshPending = false
    private var foregroundWorkspaceMutationRefreshGeneration = UUID()
    @ObservationIgnored var notificationFeedSnapshotsByMac: [String: NotificationFeedMacSnapshot] = [:]
    @ObservationIgnored var notificationFeedKnownRevisionsByMac: [String: Int] = [:]
    @ObservationIgnored var notificationFeedSuccessfulMacIDs: Set<String> = []
    @ObservationIgnored var notificationFeedRefreshTasksByMac:
        [String: Task<NotificationFeedFetchOutcome, Never>] = [:]
    @ObservationIgnored var notificationFeedRefreshTokensByMac: [String: UUID] = [:]
    @ObservationIgnored var notificationFeedRefreshPendingMacIDs: Set<String> = []
    @ObservationIgnored var notificationFeedRefreshRetryTasksByMac:
        [String: Task<NotificationFeedFetchOutcome, Never>] = [:]
    @ObservationIgnored var notificationFeedRefreshRetryTokensByMac: [String: UUID] = [:]
    @ObservationIgnored var notificationFeedRefreshGenerationByMac: [String: UInt64] = [:]
    @ObservationIgnored var notificationFeedRefreshRetryConsumedGenerationByMac: [String: UInt64] = [:]
    @ObservationIgnored var notificationFeedOpenTask: Task<Void, Never>?
    @ObservationIgnored var notificationFeedOpenToken: UUID?
    let notificationFeedAggregation = MobileNotificationFeedAggregation()
    var createWorkspaceTaskID: UUID?
    private var createTerminalTaskID: UUID?
    var connectionGeneration: UUID
    var connectionAttemptGeneration: UUID
    @ObservationIgnored var macSwitchAttemptID: UUID?
    @ObservationIgnored var macSwitchAttemptSignInGeneration: Int?
    @ObservationIgnored var macSwitchRestorePreviousOnCancelAttemptIDs: Set<UUID> = []
    @ObservationIgnored var macSwitchRestoreBaseline: MobilePairedMac?
    @ObservationIgnored private var macSwitchCancelRestoreGeneration: UInt64 = 0
    /// Focus generations whose terminal subscription has been removed for a
    /// role handoff but whose registry transition has not committed yet.
    @ObservationIgnored var focusedHandoffPreparedGenerations: Set<UUID> = []
    /// One authoritative per-Mac connection registry. Compatibility accessors
    /// below keep focused/control call sites reviewable while every mutation
    /// lands in this single role-aware map.
    private let macConnectionRegistry = MobileMacConnectionRegistry()
    var connections: MobileMacConnectionRegistry.FocusedConnections {
        macConnectionRegistry.focusedConnections
    }
    var foregroundMacDeviceID: String? {
        didSet {
            if let foregroundMacDeviceID {
                recoveryTargetMacDeviceID = foregroundMacDeviceID
                recoveryTargetInstanceTag = activeMacInstanceTag
            }
            recomputeDerivedWorkspaceState()
        }
    }
    /// The Mac the foreground connection most recently targeted. Survives
    /// `clearRemoteConnectionContext()`, which nils `foregroundMacDeviceID`
    /// before a bounded redial begins, so recovery-scoped UI keeps attributing
    /// the in-flight redial (and its failure) to the workspace that owns it
    /// instead of falling back to an actionable disconnected state mid-dial.
    /// Cleared on sign-out.
    private(set) var recoveryTargetMacDeviceID: String?
    /// The recovery target's build tag, retained with the device id so
    /// recovery-scoped UI attributes flags to the exact pairing being
    /// redialed, never a healthy sibling build on the same physical Mac.
    private(set) var recoveryTargetInstanceTag: String?
    /// The foreground pairing that a new connection attempt replaces. During
    /// recovery the live identity is intentionally cleared before redial, so
    /// the retained target remains the ownership authority for distinguishing
    /// a same-Mac reconnect from a real Mac switch.
    private var foregroundOrRecoveryMacKey: MacPairingKey {
        guard foregroundMacDeviceID == nil,
              let recoveryTargetMacDeviceID else {
            return foregroundMacKey
        }
        return MacPairingKey(
            macDeviceID: recoveryTargetMacDeviceID,
            instanceTag: recoveryTargetInstanceTag
        )
    }
    /// Compatibility view over registry entries whose role is `.control`.
    var secondaryMacSubscriptions: MobileMacConnectionRegistry.ControlSubscriptions {
        macConnectionRegistry.controlSubscriptions
    }

    /// Live per-Mac connections for Settings and diagnostics, focused first.
    public var liveMacConnections: [MobileMacConnectionSnapshot] {
        macConnectionRegistry.snapshots
    }
    /// The in-flight multi-Mac aggregation pass, tracked so sign-out / account
    /// switch can cancel it; its scope guards then bail before any cross-account
    /// write. Repeated presence pushes set a trailing-pass bit instead of
    /// cancelling an authenticated Iroh handshake mid-flight.
    private var secondaryAggregationTask: Task<Void, Never>?
    private var secondaryAggregationTaskGeneration = UUID()
    private var secondaryAggregationPending = false
    /// A foreground connection or explicit refresh requested one fresh broker
    /// discovery pass. Kept separate from ordinary store aggregation so
    /// presence churn never turns same-account discovery into polling.
    private var secondaryIrohDiscoveryPending = false
    /// Incremental presence edges are reconciled only for their affected Macs.
    /// One coalesced task drains the pending id set without widening each edge
    /// into a pool-wide workspace refresh.
    private var secondaryPresenceAggregationTask: Task<Void, Never>?
    private var secondaryPresenceAggregationTaskGeneration = UUID()
    private var secondaryPresencePendingMacIDs: Set<String> = []
    /// Full and targeted aggregation are independent coalescers. This keyed
    /// single-flight is their shared publication owner, preventing two
    /// suspended dials from installing control connections for one physical Mac.
    @ObservationIgnored
    private var secondaryMacEstablishmentFlights:
        [MacPairingKey: SecondaryMacEstablishmentFlight] = [:]
    /// Foreground route authority is published before its dial begins.
    /// Background aggregation consults this reservation so a previously
    /// selected control candidate cannot occupy the foreground route.
    @ObservationIgnored
    private var foregroundConnectionAttemptReservation:
        ForegroundConnectionAttemptReservation?
    /// Retired control clients whose physical transport is still draining.
    /// These entries block another same-Mac dial without appearing in the live
    /// registry or remaining available to workspace and notification actions.
    @ObservationIgnored var secondaryMacDrainReservations:
        [MacPairingKey: SecondaryMacSubscription] = [:]
    /// Scope-bound index backing targeted presence reconciliation. Route writes
    /// refresh this cache before enqueueing their presence edge, so one Mac's
    /// heartbeat can inspect that Mac plus the bounded live pool without
    /// reloading and sorting every paired row on the main actor.
    @ObservationIgnored
    private var storedPairedMacsByCanonicalDeviceID:
        [String: [MobilePairedMac]] = [:]
    /// Scope-bound physical-route alias groups for targeted presence edges,
    /// keyed by the exact stored pairing id (device + app-instance tag).
    /// The cache is built with the full stored snapshot so an event for a
    /// historical device id can reconcile the current representative without
    /// scanning every paired row on each heartbeat.
    @ObservationIgnored
    private var storedPairedMacAliasCanonicalIDsByCanonicalID:
        [String: Set<String>] = [:]
    /// Scope-bound physical-route aliases indexed by canonical hardware id.
    /// Targeted presence reconciliation uses this derived index so lookup cost
    /// scales with the requested computers rather than every stored pairing.
    @ObservationIgnored
    private var storedPairedMacAliasCanonicalIDsByDeviceID:
        [String: Set<String>] = [:]
    @ObservationIgnored
    private var storedPairedMacCacheScope: MobileShellScopeSnapshot?
    /// Coalesced retry after any control-pool dial or stream failure. One task
    /// covers all online Macs so simultaneous cellular path loss does not fan
    /// out timers.
    var secondaryAggregationRetryTask: Task<Void, Never>?
    private var secondaryAggregationRetryTaskGeneration = UUID()
    var secondaryAggregationRetryMacIDs: Set<String> = []
    var secondaryAggregationRetryNeedsFullRefresh = false
    private var secondaryAggregationRetryEvidenceGeneration: UInt64 = 0
    private var secondaryAggregationRetryState = MobileControlPoolRetryState()
    /// One timer owner for the whole online control pool. Each tick reasserts
    /// every lightweight subscription, avoiding one long-lived timer per Mac.
    private var secondaryControlKeepaliveTask: Task<Void, Never>?
    private var secondaryControlKeepaliveTaskGeneration = UUID()
    /// Per-Mac RPCs in the current tick. Promotion waits only for its target,
    /// not every online Mac in the shared pass, before canceling the timer.
    private var secondaryControlReassertionTasksByOwnerKey:
        [MacPairingKey: Task<SecondaryOwnedEventSubscriptionActivation, Never>] = [:]
    private var secondaryControlReassertionTokensByOwnerKey: [MacPairingKey: UUID] = [:]
    private var secondaryControlReassertionOwnerIDsByOwnerKey:
        [MacPairingKey: ObjectIdentifier] = [:]
    /// Cleanup for paired-Mac backup reads crossing a team boundary. This task
    /// never owns a transport dial; startup connection ownership lives at the
    /// app root so scope notifications cannot replace an admitted Iroh client.
    private var teamScopeCleanupTask: Task<Void, Never>?
    /// Bumped on Stack team switches so every aggregation caller, including
    /// direct pull-to-refresh calls that are not owned by
    /// ``secondaryAggregationTask``, can reject old-team results after awaits.
    var secondaryAggregationScopeGeneration = 0
    var reportedViewportSizesByTerminalKey: [MobileTerminalViewportKey: MobileTerminalViewportSize]
    var effectiveViewportSizesBySurfaceID: [String: MobileTerminalViewportSize]; var reportedTerminalViewportSizesBySurfaceID: [String: MobileTerminalViewportSize]
    /// Monotonic viewport fences scoped to the Mac app instance that consumes
    /// them. Warm Iroh focus swaps keep both peer connections alive, so their
    /// counters must survive independently for the signed-in account lifetime.
    var viewportReportGenerationsBySequenceKey: [MobileTerminalViewportSequenceKey: UInt64]
    var deliveredTerminalByteEndSeqBySurfaceID: [String: UInt64]
    /// Pre-barrier delivered high-water mark: rejects buffered pre-barrier
    /// frames, and is restored as the baseline on an empty barrier release.
    var terminalPreBarrierDeliveredEndSeqBySurfaceID: [String: UInt64]
    var terminalRenderGridBaselineReplayRequestCountsBySurfaceID: [String: Int]
    var terminalRenderGridBaselineReplayBarrierTokensBySurfaceID: [String: UUID]
    var terminalAlternateRenderGridBaselineSurfaceIDs: Set<String>
    var terminalFullReplacementSeqBySurfaceID: [String: UInt64]
    var terminalFullReplacementGenerationBySurfaceID: [String: UInt64]
    var terminalFullReplacementGeneration: UInt64
    var pendingTerminalByteEndSeqBySurfaceID: [String: UInt64]
    var pendingTerminalInputDroppedRenderGridSurfaceIDs: Set<String>
    var terminalActiveScreenBySurfaceID: [String: MobileTerminalRenderGridFrame.Screen]
    /// History-row count of the last DELIVERED screen-anchored frame. Deltas
    /// carry the producer's previous history count as their diff base; a
    /// mismatch here means a frame was missed and dirty-row patching can no
    /// longer realign the grid or scrollback, so delivery requests a full
    /// replay instead.
    var terminalRenderGridHistoryContinuityBySurfaceID: [String: UInt64]
    /// Surfaces whose local mirror lost (or never had) its deep scrollback:
    /// cold attach and post-rebuild resets. Only these replays request the
    /// full hydration window; steady-state replays (barrier follow-ups, theme
    /// resets) request none and replay as history-preserving repaints.
    var terminalMirrorHydrationNeededSurfaceIDs: Set<String>
    var terminalReplaySurfaceIDsInFlight: Set<String>
    var terminalReplayRequestIDsInFlightBySurfaceID: [String: UUID]
    var terminalReplayTasksBySurfaceID: [String: Task<Void, Never>]
    var terminalReplayBarrierWatchdogTasksBySurfaceID: [String: Task<Void, Never>]
    var terminalReplayBarrierWatchdogIDsBySurfaceID: [String: UUID]
    var terminalReplayBarrierWatchdogTokensBySurfaceID: [String: UUID]
    var terminalReplayBarrierTokensInFlightBySurfaceID: [String: UUID]
    var terminalReplayBarrierTokensBySurfaceID: [String: UUID]
    var terminalReplayBarrierAckStreamTokensBySurfaceID: [String: UUID]
    var terminalReplayBarrierDroppedOutputSurfaceIDs: Set<String>
    var terminalReplayBarrierDroppedOutputCountsBySurfaceID: [String: UInt64]
    var terminalReplayBarrierAckCoveredDroppedOutputCountsBySurfaceID: [String: UInt64]
    var terminalViewportReplayBarrierPendingAckTokensBySurfaceID: [String: UUID]
    var terminalReplayFailureRetryCountsBySurfaceID: [String: Int]
    var terminalReplayBarrierFollowUpCountsBySurfaceID: [String: Int]
    var terminalColdAttachReplayBarrierTokensBySurfaceID: [String: UUID]
    var terminalColdReplayNeedsBarrierUpgradeSurfaceIDs: Set<String>
    var terminalOutputTransport: TerminalOutputTransport
    var terminalByteContinuationsBySurfaceID: [String: AsyncStream<MobileTerminalOutputChunk>.Continuation]
    var terminalOutputStreamTokensBySurfaceID: [String: UUID]
    /// Owner generation for the mounted UI consumer. The stream token tracks
    /// delivery acknowledgements; this identity lets an older coordinator
    /// distinguish intentional replacement from a failed stream.
    private var terminalOutputConsumerOwnerIDsBySurfaceID: [String: UUID]
    var terminalOutputQueuesBySurfaceID: [String: TerminalOutputDeliveryQueue]
    let terminalLaneCoordinator: MobileTerminalLaneCoordinator?
    var terminalLaneOutputReadySurfaceIDs: Set<String>
    var terminalLaneLifecycleID: UUID
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
    private var terminalInputRPCPipeline: MobileTerminalInputRPCPipeline
    private var rawTerminalInputDrainWaiters: [CheckedContinuation<Void, Never>]
    private var isRawTerminalInputDrainLoopRunning: Bool
    #if DEBUG
    var latencyProbeAutoNavigationTask: Task<Void, Never>?
    var latencyProbeTask: Task<Void, Never>?
    private var rawTerminalInputLatencyBatchNumber: UInt64
    #endif
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

    /// The explicitly selected workspace only — unlike ``selectedWorkspace``
    /// this never falls back to `workspaces.first`, so status/action UI can't
    /// attribute connection state to an arbitrary row when the selection was
    /// cleared (e.g. after a failed cross-Mac open).
    public var explicitlySelectedWorkspace: MobileWorkspacePreview? {
        guard let selectedWorkspaceID else { return nil }
        return workspaces.first { $0.id == selectedWorkspaceID }
    }

    /// True when the selected workspace's Mac is served by the foreground RPC
    /// connection, so the foreground recovery flags
    /// (`isRecoveringConnection`, `connectionRecoveryFailed`) describe it. A
    /// workspace on a connected secondary Mac stays healthy while the
    /// foreground connection recovers.
    public var selectedWorkspaceUsesForegroundConnection: Bool {
        // Explicit selection only: the `selectedWorkspace` fallback to
        // `workspaces.first` would attribute foreground recovery to an
        // arbitrary row when nothing is selected. No selection reads as
        // foreground, matching the aggregate list surfaces.
        guard let workspace = explicitlySelectedWorkspace,
              let macID = workspace.macDeviceID, !macID.isEmpty else {
            return true
        }
        // Fall back to the retained recovery target: automatic recovery nils
        // foregroundMacDeviceID before the redial, and the workspace being
        // redialed must keep reading as recovering, not disconnected.
        guard let ownerDeviceID = foregroundMacDeviceID ?? recoveryTargetMacDeviceID else {
            return false
        }
        guard cmxCanonicalDeviceID(macID) == cmxCanonicalDeviceID(ownerDeviceID) else {
            return false
        }
        // Same device: the row is foreground-served only when its BUILD
        // matches the live (or recovering) pairing. A sibling build's row
        // stays healthy while the foreground connection recovers.
        let ownerTag = foregroundMacDeviceID != nil
            ? activeMacInstanceTag
            : recoveryTargetInstanceTag
        return macInstanceTagAuthority.sameStoredAuthority(
            workspace.macInstanceTag,
            ownerTag
        )
    }

    /// Resolve a UI row id back to the Mac-local workspace id expected by RPC.
    ///
    /// Multi-Mac aggregation scopes row ids by Mac to avoid collisions, while
    /// the Mac host still expects its original local workspace id.
    func remoteWorkspaceID(for id: MobileWorkspacePreview.ID) -> MobileWorkspacePreview.ID {
        workspaces.first { $0.id == id }?.rpcWorkspaceID ?? id
    }

    /// Resolve an aggregate group id back to the Mac-local id expected by RPC.
    func remoteWorkspaceGroupID(
        for id: MobileWorkspaceGroupPreview.ID
    ) -> MobileWorkspaceGroupPreview.ID {
        workspaceGroups.first { $0.id == id }?.rpcGroupID ?? id
    }

    /// Resolve a Mac-local workspace id to the current UI row id.
    func rowWorkspaceID(
        forRemoteWorkspaceID remoteID: MobileWorkspacePreview.ID,
        macDeviceID: String?,
        instanceTag: String? = nil
    ) -> MobileWorkspacePreview.ID? {
        let matches = workspaces.filter {
            workspaceMatchesRemoteID($0, remoteID: remoteID, macDeviceID: macDeviceID)
                && macInstanceTagAuthority.sameStoredAuthority(
                    $0.macInstanceTag,
                    instanceTag
                )
        }
        return matches.first?.id
    }

    private func workspaceMatchesRemoteID(
        _ workspace: MobileWorkspacePreview,
        remoteID: MobileWorkspacePreview.ID,
        macDeviceID: String?
    ) -> Bool {
        guard workspace.rpcWorkspaceID == remoteID else { return false }
        guard let macDeviceID, !macDeviceID.isEmpty else {
            return workspace.macDeviceID == nil && workspace.macInstanceTag == nil
        }
        return cmxCanonicalDeviceID(workspace.macDeviceID ?? "")
            == cmxCanonicalDeviceID(macDeviceID)
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
    /// - Parameter browserStreamEvents: App-lifetime browser stream state kept outside workspace previews.
    public init(
        runtime: (any MobileSyncRuntime)? = nil,
        isSignedIn: Bool = false,
        connectionState: MobileConnectionState = .disconnected,
        connectedHostName: String = "",
        pairingCode: String = "",
        workspaces: [MobileWorkspacePreview] = [],
        pairedMacStore: (any MobilePairedMacStoring)? = nil,
        connectionMethodStore: MobileConnectionMethodStore? = nil,
        buildCompatibilityPolicy: MobileMacBuildCompatibilityPolicy? = nil,
        pairedMacRestoreBoundary: PairedMacRestoreBoundary? = nil,
        deviceRegistry: (any DeviceRegistryRefreshing)? = nil,
        personalIrohDiscovery: (any MobileIrohMacDiscovering)? = nil,
        personalIrohForget: (any MobileIrohMacForgetting)? = nil,
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
        hiddenMacStore: any PairedMacHiddenStoring = InMemoryPairedMacHiddenStore(),
        analytics: any AnalyticsEmitting = NoopAnalytics(),
        diagnosticLog: DiagnosticLog? = nil,
        feedbackEmailSubmitter: (any MobileFeedbackEmailSubmitting)? = nil,
        feedbackStampProvider: @escaping @MainActor () -> MobileFeedbackStamp = { MobileShellComposite.emptyFeedbackStamp },
        draftStore: (any TerminalDraftStoring)? = nil,
        groupCollapseStore: MobileWorkspaceGroupCollapseStore = MobileWorkspaceGroupCollapseStore(),
        workspaceSortStore: MobileWorkspaceSortStore = MobileWorkspaceSortStore(),
        workspaceChangesHintDismissalStore: MobileWorkspaceChangesHintDismissalStore = MobileWorkspaceChangesHintDismissalStore(),
        workspaceChangesSchedulingClock: any Clock<Duration> = ContinuousClock(),
        controlPlaneSchedulingClock: any Clock<Duration> = ContinuousClock(),
        connectionHandoffDrainTimeoutNanoseconds: UInt64 = 3_000_000_000,
        terminalInputAckResubscribeClock: any Clock<Duration> = ContinuousClock(),
        taskTemplateStore: (any MobileTaskTemplateStoring)? = nil,
        taskModelCatalogClient: MobileTaskModelCatalogClient = .live(),
        browserStreamEvents: (any BrowserStreamEventReceiving)? = nil,
        simulatorStreamStore: MobileSimulatorStreamStore? = nil,
        simulatorStreamStalenessClock: any Clock<Duration> = ContinuousClock(),
        storedMacReconnectRestoringDeadlineSeconds: Double = 15
    ) {
        self.runtime = runtime
        self.draftStore = draftStore
        self.groupCollapseStore = groupCollapseStore
        self.workspaceSortStore = workspaceSortStore
        self.workspaceSortMode = workspaceSortStore.mode
        self.workspaceComputerPriority = workspaceSortStore.computerPriority
        self.workspaceChangesHintDismissalStore = workspaceChangesHintDismissalStore
        self.workspaceChangesSchedulingClock = workspaceChangesSchedulingClock
        self.controlPlaneSchedulingClock = controlPlaneSchedulingClock
        self.connectionHandoffDrainTimeoutNanoseconds =
            connectionHandoffDrainTimeoutNanoseconds
        self.terminalInputAckResubscribeClock = terminalInputAckResubscribeClock
        self.taskTemplateStore = taskTemplateStore
        self.taskModelCatalogClient = taskModelCatalogClient
        self.browserStreamEvents = browserStreamEvents
        self.simulatorStreamStore = simulatorStreamStore
        self.simulatorStreamStalenessClock = simulatorStreamStalenessClock
        self.storedMacReconnectRestoringDeadlineSeconds = storedMacReconnectRestoringDeadlineSeconds
        self.pairedMacStore = pairedMacStore
        self.connectionMethodStore = connectionMethodStore
        self.buildCompatibilityPolicy = buildCompatibilityPolicy
        self.macInstanceTagAuthority = MobileMacInstanceTagAuthority()
        self.pairedMacRestoreBoundary = pairedMacRestoreBoundary
        self.deviceRegistry = deviceRegistry
        self.personalIrohDiscovery = personalIrohDiscovery
        self.personalIrohForget = personalIrohForget
        self.presence = presence
        self.identityProvider = identityProvider
        self.teamIDProvider = teamIDProvider
        self.reachability = reachability
        self.routePinger = routePinger
        self.deliveredNotificationClearer = deliveredNotificationClearer
        self.pendingDismissQueue = pendingDismissQueue
        self.pairingHintDefaults = pairingHintDefaults
        self.multiMacAggregationDefaults = multiMacAggregationDefaults
        self.hiddenMacStore = hiddenMacStore
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
            : [.anonymousForeground: MacWorkspaceState(
                macDeviceID: Self.foregroundAnonymousKey, workspaces: workspaces)]
        self.workspaces = workspaces
        self.terminalInputText = ""
        self.connectionError = nil
        self.connectionErrorGuidance = nil
        self.pairingVersionWarning = nil
        self.activeTicket = nil
        self.activeRoute = nil
        self.activeMacInstanceTag = nil
        self.selectedWorkspaceID = workspaces.first?.id
        // Let the final synchronizer apply the same focus-aware priority used
        // when a workspace changes after initialization.
        self.selectedTerminalID = nil
        self.remoteClient = nil
        self.terminalEventListenerTask = nil
        self.terminalEventListenerID = nil
        self.terminalSubscriptionRefreshTask = nil
        self.terminalInputAckResubscribeRetryTask = nil
        self.terminalInputAckResubscribeRetryTaskID = nil
        self.terminalInputAckResubscribeRetrySurfaceID = nil
        self.createWorkspaceTask = nil
        self.createWorkspaceTaskGroupID = nil
        self.createWorkspaceTaskSpec = nil
        self.createTerminalTask = nil
        self.workspaceListRefreshTask = nil
        self.pullToRefreshTask = nil
        self.foregroundWorkspaceMutationRefreshTask = nil
        self.foregroundWorkspaceMutationRefreshPending = false
        self.foregroundWorkspaceMutationRefreshGeneration = UUID()
        self.createWorkspaceTaskID = nil
        self.createTerminalTaskID = nil
        self.connectionGeneration = UUID()
        self.connectionAttemptGeneration = UUID()
        self.reportedViewportSizesByTerminalKey = [:]
        self.effectiveViewportSizesBySurfaceID = [:]; self.reportedTerminalViewportSizesBySurfaceID = [:]
        self.viewportReportGenerationsBySequenceKey = [:]
        self.deliveredTerminalByteEndSeqBySurfaceID = [:]
        self.terminalPreBarrierDeliveredEndSeqBySurfaceID = [:]
        self.terminalRenderGridBaselineReplayRequestCountsBySurfaceID = [:]
        self.terminalRenderGridBaselineReplayBarrierTokensBySurfaceID = [:]
        self.terminalAlternateRenderGridBaselineSurfaceIDs = []
        self.terminalFullReplacementSeqBySurfaceID = [:]
        self.terminalFullReplacementGenerationBySurfaceID = [:]
        self.terminalFullReplacementGeneration = 0
        self.pendingTerminalByteEndSeqBySurfaceID = [:]
        self.pendingTerminalInputDroppedRenderGridSurfaceIDs = []
        self.terminalActiveScreenBySurfaceID = [:]
        self.terminalRenderGridHistoryContinuityBySurfaceID = [:]
        self.terminalMirrorHydrationNeededSurfaceIDs = []
        self.terminalReplaySurfaceIDsInFlight = []
        self.terminalReplayRequestIDsInFlightBySurfaceID = [:]
        self.terminalReplayTasksBySurfaceID = [:]
        self.terminalReplayBarrierWatchdogTasksBySurfaceID = [:]
        self.terminalReplayBarrierWatchdogIDsBySurfaceID = [:]
        self.terminalReplayBarrierWatchdogTokensBySurfaceID = [:]
        self.terminalReplayBarrierTokensInFlightBySurfaceID = [:]
        self.terminalReplayBarrierTokensBySurfaceID = [:]
        self.terminalReplayBarrierAckStreamTokensBySurfaceID = [:]
        self.terminalReplayBarrierDroppedOutputSurfaceIDs = []
        self.terminalReplayBarrierDroppedOutputCountsBySurfaceID = [:]
        self.terminalReplayBarrierAckCoveredDroppedOutputCountsBySurfaceID = [:]
        self.terminalViewportReplayBarrierPendingAckTokensBySurfaceID = [:]
        self.terminalReplayFailureRetryCountsBySurfaceID = [:]
        self.terminalReplayBarrierFollowUpCountsBySurfaceID = [:]
        self.terminalColdAttachReplayBarrierTokensBySurfaceID = [:]
        self.terminalColdReplayNeedsBarrierUpgradeSurfaceIDs = []
        self.terminalOutputTransport = .rawBytes
        self.terminalByteContinuationsBySurfaceID = [:]
        self.terminalOutputStreamTokensBySurfaceID = [:]
        self.terminalOutputConsumerOwnerIDsBySurfaceID = [:]
        self.terminalOutputQueuesBySurfaceID = [:]
        if let terminalLaneProvider = runtime?.terminalLaneProvider {
            self.terminalLaneCoordinator = MobileTerminalLaneCoordinator(
                provider: terminalLaneProvider
            )
        } else {
            self.terminalLaneCoordinator = nil
        }
        self.terminalLaneOutputReadySurfaceIDs = []
        self.diagnosedTerminalOutputSurfaceIDs = []
        self.terminalLaneLifecycleID = UUID()
        self.terminalScrollQueueTokensBySurfaceID = [:]
        self.terminalScrollQueuesBySurfaceID = [:]
        self.terminalScrollbackPrefetchStatesBySurfaceID = [:]
        self.terminalLiveFontContinuationsBySurfaceID = [:]
        self.terminalLiveFontTokensBySurfaceID = [:]
        self.rawTerminalInputBuffer = MobileTerminalInputSendBuffer()
        self.terminalInputRPCPipeline = MobileTerminalInputRPCPipeline()
        self.rawTerminalInputDrainWaiters = []
        self.isRawTerminalInputDrainLoopRunning = false
        #if DEBUG
        self.latencyProbeAutoNavigationTask = nil
        self.latencyProbeTask = nil
        self.rawTerminalInputLatencyBatchNumber = 0
        #endif
        self.pairingAttemptID = UUID()
        // The watchdog's re-arm must bypass the started-dedupe set: unanswered
        // input means the Mac-side session is gone (or never took), whatever
        // the phone's bookkeeping says.
        browserStreamEvents?.configureBrowserStreamRestart { [weak self] panelID in
            await self?.forceRestartMobileBrowserStream(panelID: panelID)
        }
        startObservingConnectionMethodChanges()
        selectedTerminalID = nil
        selectedMacSurfaceID = nil
        syncSelectedTerminalForWorkspace()
    }

    isolated deinit {
        connectionRecoveryOwner.cancel()
        connectionRecoveryAttemptDeadlineTask?.cancel()
        automaticReconnectRetryTask?.cancel()
        presenceTask?.cancel()
        networkPathObservationTask?.cancel()
        connectionMethodObservationTask?.cancel()
        terminalEventListenerTask?.cancel()
        terminalSubscriptionStartTask?.cancel()
        renderGridLivenessTimer?.cancel()
        renderGridLivenessProbeTask?.cancel()
        terminalInputAckResubscribeRetryTask?.cancel()
        terminalSubscriptionRefreshTask?.cancel()
        createWorkspaceTask?.cancel()
        createTerminalTask?.cancel()
        workspaceListRefreshTask?.cancel()
        workspaceChangesSummaryDebounceTask?.cancel()
        workspaceChangesSummaryFetchTask?.cancel()
        workspaceChangesSummaryTrailingTask?.cancel()
        pullToRefreshTask?.cancel()
        foregroundWorkspaceMutationRefreshTask?.cancel()
        for task in computerVisibilityMutationTasksByID.values {
            task.cancel()
        }
        foregroundWorkspaceMutationRefreshPending = false
        foregroundWorkspaceMutationRefreshGeneration = UUID()
        notificationFeedOpenTask?.cancel()
        teamScopeCleanupTask?.cancel()
        cancelAllTerminalReplayTasks()
        teardownSecondaryMacSubscriptions()
        let terminalLaneCoordinator = terminalLaneCoordinator
        Task { await terminalLaneCoordinator?.deactivateAll() }
        if let remoteClient {
            Task { await remoteClient.disconnect() }
        }
    }

    public static func preview(
        runtime: (any MobileSyncRuntime)? = nil,
        terminalInputAckResubscribeClock: any Clock<Duration> = ContinuousClock(),
        controlPlaneSchedulingClock: any Clock<Duration> = ContinuousClock()
    ) -> CMUXMobileShellStore {
        CMUXMobileShellStore(
            runtime: runtime,
            workspaces: PreviewMobileHost.workspaces,
            deliveredNotificationClearer: NoopDeliveredNotificationClearer(),
            controlPlaneSchedulingClock: controlPlaneSchedulingClock,
            terminalInputAckResubscribeClock: terminalInputAckResubscribeClock
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
        cancelComputerVisibilityMutations()
        // Reset analytics identity to anonymous on the signed-in→signed-out edge
        // only (this is called on every unauthenticated auth-state sync).
        if isSignedIn {
            analytics.identify(userId: nil, alias: nil, properties: [:])
            analytics.setSuperProperties(["is_authenticated": .bool(false)])
        }
        suppressNextConnectionOutageEdge = true
        clearAutomaticReconnectBackoff()
        // The state-sync mirror caches workspace/terminal titles, directories,
        // and notification previews from the previous account's Macs; it must
        // not survive an account boundary or leak into the next session's
        // projections.
        resetStateSyncForAccountBoundary()
        lastPresenceReconnectEvidence = nil
        presencePushRecoveryThrottle.reset()
        pendingInactiveRecoveryTrigger = nil
        connectionRecoveryOwner.cancel()
        applyConnectionRecoveryOwnerState()
        invalidatePairingAttempt()
        clearMacSwitchAttemptState()
        connectionGeneration = UUID()
        connectionAttemptGeneration = UUID()
        isSignedIn = false
        connectionState = .disconnected
        macConnectionStatus = .unavailable
        connectedHostName = ""
        pairingCode = ""
        clearPairingVersionWarning()
        // Wipe every draft so the next account never sees its predecessor's text.
        // Guard the in-memory clear and selection resets so per-terminal hooks do
        // not write partial state into a store we are emptying wholesale.
        isLoadingDraft = true
        terminalInputText = ""
        // Enqueued on the FIFO draft pipeline so every save issued before this
        // point is applied first and then wiped; a pending keystroke save can
        // never land after the wipe and leak into the next account's session.
        if let draftStore {
            enqueueDraftOperation { await draftStore.clearAllDrafts() }
        }
        taskTemplateStore?.clearAllUserData()
        taskModelCache.removeAll()
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
        clearStoredPairedMacCache()
        pairedMacAliasIDsByRepresentativeID = [:]
        pairedMacs = []
        pairedMacLoadState = .notLoaded
        hiddenComputers = []
        hasHiddenComputers = false
        resetTerminalThemes()
        // Likewise drop the registry-backed device tree so a shared device never
        // shows the previous user's team devices after sign-out.
        registryDevices = []
        // Reset the in-memory restoring flags; hasKnownPairedMac stays driven by
        // the hide path. On a real account switch the next reconnect's no-mac
        // branch clears the hint. Bump the reconnect generation so any in-flight
        // reconnect is superseded and can't re-set these flags after sign-out.
        storedMacReconnectGeneration &+= 1
        isReconnectingStoredMac = false
        pendingForcedStoredMacReconnect = false
        didFinishStoredMacReconnectAttempt = false
        replaceRemoteClient(with: nil)
        cancelRemoteOperationTasks()
        resetNotificationFeed()
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
        teamScopeCleanupTask?.cancel()
        teamScopeCleanupTask = nil
        if let refresher = pairedMacStore as? any PairedMacBackupRefreshing {
            Task { await refresher.cancelInFlightRestores() }
        }
        rawTerminalInputBuffer.clear()
        terminalInputRPCPipeline.clear()
        resumeRawTerminalInputDrainWaiters()
        reportedViewportSizesByTerminalKey = [:]
        viewportReportGenerationsBySequenceKey = [:]
        terminalPreBarrierDeliveredEndSeqBySurfaceID = [:]
        terminalRenderGridBaselineReplayRequestCountsBySurfaceID = [:]
        terminalRenderGridBaselineReplayBarrierTokensBySurfaceID = [:]
        terminalColdAttachReplayBarrierTokensBySurfaceID = [:]
        terminalAlternateRenderGridBaselineSurfaceIDs = []
        terminalFullReplacementSeqBySurfaceID = [:]
        terminalFullReplacementGenerationBySurfaceID = [:]
        terminalFullReplacementGeneration = 0
        // Reset foreground identity to anonymous BEFORE clearing the per-Mac
        // state below: otherwise the next `connect()` captures the stale real Mac
        // id as `previousForegroundKey` and `dropStalePreviousForeground` drops
        // the wrong key. Also drop the foreground connection-pool entry so a
        // stale per-Mac connection can't be reused.
        foregroundMacDeviceID = nil
        recoveryTargetMacDeviceID = nil
        recoveryTargetInstanceTag = nil
        connections.removeAll()
        // A signed-out store owns no Macs: clear the per-Mac source of truth so
        // `workspaces`/`workspaceGroups` derive to empty. Group sections are
        // account-scoped like `pairedMacs`/`registryDevices` above: the previous
        // account's group names must not survive into the next session. Never
        // seed `PreviewMobileHost` fixtures here — those fake "cmux"/"Docs" rows
        // rendered as real disconnected workspaces on first launch and lingered
        // after sign-in until the Mac connected.
        workspacesByMac = [:]
        resetStableMacColorSlotsForSignOut()
        selectedWorkspaceID = nil
        selectedTerminalID = nil
        // Selection resets above are done; allow draft saving again so a
        // subsequent sign-in restores drafts normally.
        isLoadingDraft = false
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
        cancelComputerVisibilityMutations()
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
        workspacesByMac = workspacesByMac.filter { $0.key == foregroundKey }; pruneStableMacColorSlots(keepingForegroundKey: foregroundKey.pairingID)
        retainForegroundNotificationFeedSnapshot()
        // Restore memo: invalidate so the next read re-restores for the new
        // (account, team) scope, and a suspended old-team restore can't resume.
        // Invalidate the shared boundary synchronously first; actor cleanup is
        // fire-and-forget (this method is sync) and does not wipe the local store.
        clearMacSwitchAttemptState(invalidateUnderlyingConnectionAttempt: true)
        // A reconnect that captured the previous team must not finish against the
        // new scope. Starting the replacement is deliberately left to the app
        // root's startup coordinator.
        storedMacReconnectGeneration &+= 1
        isReconnectingStoredMac = false
        pendingForcedStoredMacReconnect = false
        didFinishStoredMacReconnectAttempt = false
        pairedMacRestoreBoundary?.invalidate()
        let refresher = pairedMacStore as? any PairedMacBackupRefreshing
        // Lazy display: clear the stale old-team lists; the next loadPairedMacs() /
        // loadRegistryDevices() (DeviceTreeView `.task`) repopulate scoped to the
        // new team. The foreground workspace list (derived from the kept entry) is
        // unaffected.
        storedPairedMacs = []
        clearStoredPairedMacCache()
        pairedMacAliasIDsByRepresentativeID = [:]
        pairedMacs = []
        pairedMacLoadState = .notLoaded
        hiddenMacDeviceIDsByScope = [:]
        hiddenComputers = []
        hasHiddenComputers = false
        registryDevices = []
        teamScopeCleanupTask?.cancel()
        teamScopeCleanupTask = Task {
            if let refresher {
                await refresher.cancelInFlightRestores()
            }
        }
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
        let startedAt = appDiagnosticNow()
        let stamp = currentFeedbackStamp
        let route = currentFeedbackRoute
        let initialDiagnosticRoute: DiagnosticFeedbackRoute = route == .privilegedAgent
            ? .privilegedAgent
            : .email
        recordAppEvent(
            .feedbackSubmitStarted,
            detail: .feedbackRoute(initialDiagnosticRoute)
        )
        let outcome: FeedbackSubmissionOutcome
        switch route {
        case .privilegedAgent:
            let ok = await submitPrivilegedAgentFeedback(
                text: message,
                debugLogText: debugLogText,
                terminalText: terminalText,
                buildStamp: stamp.agentBuildStamp
            )
            if ok {
                outcome = .sentToAgent
                break
            }
            // The agent sink failed (e.g. the Mac rejected the privileged sink,
            // or the RPC could not be delivered). Fall back to the email inbox
            // rather than dead-ending, so the report is still delivered. Any
            // valid reply-to works; we have the signed-in email here.
            mobileShellLog.error("privileged agent feedback failed; falling back to email")
            outcome = await submitFeedbackEmail(
                message: message,
                emailOverride: emailOverride,
                stamp: stamp
            )
        case .email:
            outcome = await submitFeedbackEmail(
                message: message,
                emailOverride: emailOverride,
                stamp: stamp
            )
        }
        let finalDiagnosticRoute: DiagnosticFeedbackRoute = switch (route, outcome) {
        case (.privilegedAgent, .emailed): .privilegedAgentFallbackToEmail
        case (.privilegedAgent, _): .privilegedAgent
        case (.email, _): .email
        }
        switch outcome {
        case .sentToAgent, .emailed:
            recordAppEvent(
                .feedbackSubmitSucceeded,
                startedAt: startedAt,
                detail: .feedbackRoute(finalDiagnosticRoute)
            )
        case .failed:
            recordAppEvent(
                .feedbackSubmitFailed,
                startedAt: startedAt,
                failure: .unknown,
                detail: .feedbackRoute(finalDiagnosticRoute)
            )
        }
        return outcome
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
    public internal(set) var isRecoveringConnection: Bool = false
    /// True when automatic recovery could not restore the connection; the UI
    /// surfaces a manual Retry control in this state.
    public internal(set) var connectionRecoveryFailed: Bool = false {
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

    var networkPathObservationStarted = false
    var networkPathObservationTask: Task<Void, Never>?
    var connectionMethodObservationTask: Task<Void, Never>?
    let connectionRecoveryOwner = MobileConnectionRecoveryOwner()
    var lastReconnectStackUserID: String?
    /// Whether the scene is in the active phase. Set by
    /// `resumeForegroundRefresh()` / `suspendForegroundRefresh()`. Recovery
    /// triggers that arrive while false park in
    /// `pendingInactiveRecoveryTrigger` instead of dialing: a dial launched
    /// during the backgrounding bounce suspends with the process (field
    /// traces showed ~9.5s stalls) and then competes with the foreground
    /// recovery pass.
    var foregroundRefreshIsActive = true
    /// The view can report `onAppear` and `.active` for the same foreground
    /// transition. Track the shell-owned lifecycle edge separately from the
    /// active gate so duplicate callbacks cannot supersede an in-flight probe.
    /// `.inactive` never enters this state machine; only a real `.background`
    /// transition suspends transport work.
    enum ForegroundRefreshLifecycleState {
        case uninitialized
        case active
        case background
    }
    var foregroundRefreshLifecycleState =
        ForegroundRefreshLifecycleState.uninitialized
    /// The most recent recovery trigger parked while inactive, replayed once
    /// by `recoverPendingInactiveRecoveryIfNeeded()` on foreground.
    var pendingInactiveRecoveryTrigger: RecoveryTrigger?

    enum RecoveryTrigger: CustomStringConvertible {
        case networkChange
        case manual
        case presencePush
        case foreground
        case liveness
        case eventStreamEnded
        case subscriptionStartFailed
        case transportWriteTimedOut
        case automaticBackoffExpired
        case connectionMethodChanged

        var reschedulesSecondaryAggregation: Bool { self != .presencePush }

        /// Stable integer carried in ``DiagnosticEventCode/recoveryStarted``'s
        /// `b` slot so an export names WHY each recovery cycle began. Values
        /// are append-only; never renumber.
        var diagnosticCode: Int {
            switch self {
            case .networkChange: 1
            case .manual: 2
            case .presencePush: 3
            case .foreground: 4
            case .liveness: 5
            case .eventStreamEnded: 6
            case .subscriptionStartFailed: 7
            case .transportWriteTimedOut: 8
            case .automaticBackoffExpired: 9
            case .connectionMethodChanged: 10
            }
        }

        var description: String {
            switch self {
            case .networkChange: return "networkChange"
            case .manual: return "manual"
            case .presencePush: return "presencePush"
            case .foreground: return "foreground"
            case .liveness: return "liveness"
            case .eventStreamEnded: return "eventStreamEnded"
            case .subscriptionStartFailed: return "subscriptionStartFailed"
            case .transportWriteTimedOut: return "transportWriteTimedOut"
            case .automaticBackoffExpired: return "automaticBackoffExpired"
            case .connectionMethodChanged: return "connectionMethodChanged"
            }
        }
    }

    /// Begin observing meaningful network path changes (Wi-Fi<->cellular,
    /// offline->online) so a live terminal recovers when the network moves out
    /// from under it. Idempotent; only the first call arms the observation.
    public func retryMobileConnection() {
        connectionRecoveryFailed = false
        recoverMobileConnection(trigger: .manual)
    }

    public func connectPreviewHost() {
        let trimmedCode = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            return
        }
        if CmxPairingURLScheme(urlString: trimmedCode) != nil {
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
        if CmxPairingURLScheme(urlString: trimmedCode) != nil {
            // The pairing input field is an explicit in-app code entry (scan
            // or paste), the act that authorizes a compatibility Tailscale dial.
            await connectPairingURLResult(trimmedCode, userEnteredPairingCode: true)
            return
        }
        connectPreviewHost()
    }

    /// Connect to a manually-entered Mac host and optionally associate the
    /// resulting session with an existing paired-Mac device id.
    public func connectManualHost(
        name: String,
        host: String,
        port: Int,
        pairedMacDeviceID: String? = nil
    ) async {
        await connectManualHost(
            name: name,
            host: host,
            port: port,
            pairedMacDeviceID: pairedMacDeviceID,
            recordsPairingAttempt: true
        )
    }

    func connectManualHost(
        name: String,
        host: String,
        port: Int,
        pairedMacDeviceID: String? = nil,
        instanceTagExpectation: MobileMacInstanceTagExpectation = .adopt,
        recordsPairingAttempt: Bool,
        ifStillCurrent: (() -> Bool)? = nil
    ) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedHost = MobileShellRouteAuthPolicy.normalizedManualHost(host) else {
            if recordsPairingAttempt {
                recordAppEvent(.pairingStarted)
                recordAppEvent(.pairingFailed, failure: .protocolViolation)
            }
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
            if recordsPairingAttempt {
                recordAppEvent(.pairingStarted)
                recordAppEvent(.pairingFailed, failure: .protocolViolation)
            }
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

        let directRoute = try? Self.manualHostRoute(
            host: normalizedHost,
            port: port
        )
        let sameRouteProbeClient: MobileCoreRPCClient? = directRoute.flatMap { route in
            guard remoteClient?.sharesPhysicalTransportRoute(
                with: route
            ) == true else {
                return nil
            }
            return remoteClient
        }
        if sameRouteProbeClient == nil {
            activeRoute = directRoute
        }
        let attemptID: UUID
        if sameRouteProbeClient != nil {
            attemptID = recordsPairingAttempt
                ? beginPairingValidationAttempt(method: "manual")
                : beginPairingValidationAttempt()
            clearPairingError()
            clearPairingVersionWarning()
        } else {
            attemptID = recordsPairingAttempt
                ? beginPairingAttempt(method: "manual")
                : beginPairingValidationAttempt()
        }
        // Fast offline preflight: fail immediately instead of stacking
        // per-route timeouts into the opaque ~60s blob.
        let manualRoutes = directRoute.map { [$0] } ?? []
        if sameRouteProbeClient == nil {
            guard await failPairingIfOffline(
                attemptID: attemptID,
                phase: "preflight",
                routes: manualRoutes
            ) == .proceed else {
                return
            }
        }
        do {
            let ticket = try await manualHostTicket(
                name: trimmedName,
                host: normalizedHost,
                port: port,
                attemptStartedAt: pairingAttemptStartedAt,
                probeClient: sameRouteProbeClient
            )
            guard isCurrentPairingAttempt(attemptID),
                  ifStillCurrent?() ?? true else {
                return
            }
            if let sameRouteProbeClient {
                guard remoteClient === sameRouteProbeClient else { return }
                preparePairingConnectionAttempt()
            }
            let noThrowFailure = try await connect(
                ticket: ticket,
                allowsStackAuthFallback: true,
                pairedMacDeviceID: pairedMacDeviceID,
                instanceTagExpectation: instanceTagExpectation,
                ifStillCurrent: ifStillCurrent
            )
            guard isCurrentPairingAttempt(attemptID) else { return }
            if connectionState == .connected {
                // `connect()` persists the manual pairing, while Settings,
                // the Mac picker, and the task composer read the shared
                // in-memory list. Refresh it before dismissing PairingView so
                // those surfaces can use the new Mac immediately.
                await loadPairedMacs()
                guard isCurrentPairingAttempt(attemptID) else { return }
                recordPairingSucceeded()
            } else {
                // `connect()` returned without connecting and already set a
                // specific error; record without overwriting that message.
                recordFailureForCurrentConnectionError(phase: "connect", category: noThrowFailure)
            }
        } catch is CancellationError {
            guard isCurrentPairingAttempt(attemptID) else { return }
            if sameRouteProbeClient.map({ remoteClient === $0 }) == true {
                return
            }
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
            if sameRouteProbeClient.map({ remoteClient === $0 }) == true {
                return
            }
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
    public func reconnectActiveMacIfAvailable(
        stackUserID: String?,
        refreshBackupBeforeDial: Bool = true,
        force: Bool = false
    ) async -> Bool {
        let startedAt = appDiagnosticNow()
        recordAppEvent(.reconnectStarted)
        let outcome = await reconnectActiveMacOutcome(
            stackUserID: stackUserID,
            refreshBackupBeforeDial: refreshBackupBeforeDial,
            force: force
        )
        switch outcome {
        case .connected:
            recordAppEvent(
                .reconnectSucceeded,
                correlationID: foregroundMacDeviceID,
                startedAt: startedAt
            )
        case .failed(let failure):
            recordAppEvent(
                .reconnectFailed,
                startedAt: startedAt,
                failure: failure
            )
        case .superseded:
            recordAppEvent(
                .reconnectFailed,
                startedAt: startedAt,
                failure: .superseded
            )
        }
        return outcome.didConnect
    }

    /// Starts one user-requested retry and exposes its loading state before any await.
    @discardableResult
    public func retryActiveMacReconnect(
        stackUserID: String?,
        force: Bool = false
    ) async -> Bool {
        guard !isReconnectingStoredMac else {
            if force { pendingForcedStoredMacReconnect = true }
            return false
        }
        if let accountID = stackUserID ?? identityProvider?.currentUserID {
            clearTransientAutomaticReconnectBackoff(accountID: accountID)
        }
        isReconnectingStoredMac = true
        return await reconnectActiveMacIfAvailable(
            stackUserID: stackUserID,
            force: force
        )
    }

    func reconnectActiveMacOutcome(
        stackUserID: String?,
        refreshBackupBeforeDial: Bool = true,
        force: Bool = false
    ) async -> StoredMacReconnectOutcome {
        lastReconnectStackUserID = stackUserID
        startObservingNetworkPathChanges()
        // Lifecycle/auth callbacks may request restoration after an explicit
        // attach already established the foreground session. Treat the live
        // client as authoritative instead of replacing it with another client
        // for the same saved route.
        guard force || !hasActiveMacConnection else {
            finishStoredMacReconnectAttempt(generation: storedMacReconnectGeneration)
            return .connected
        }
        // Claim this attempt's generation. Only the current generation may resolve
        // the restoring-gate flags, so an older superseded attempt can't clear the
        // gate (or clobber the hint) while a newer reconnect is still running.
        storedMacReconnectGeneration &+= 1
        let generation = storedMacReconnectGeneration
        isReconnectingStoredMac = true
        let restoringDeadlineSeconds = storedMacReconnectRestoringDeadlineSeconds
        // Bound the complete visible retry window, including scope resolution,
        // backup refresh, and local-store reads before dialing starts.
        let restoringDeadline = Task { [weak self] in
            try? await ContinuousClock().sleep(
                for: .seconds(restoringDeadlineSeconds)
            )
            guard let self, !Task.isCancelled,
                  generation == self.storedMacReconnectGeneration,
                  self.connectionState != .connected else { return }
            // Resolve only the visible restoring flags; the dial may still be
            // legitimately in flight (slow network, wedged physical cleanup
            // ahead of it in the transport queue). Superseding the generation
            // here used to discard a dial that then completed successfully
            // seconds later: the adoption guards refused the freshly admitted
            // session, leaking it, and the UI stayed at Not Connected with
            // nothing scheduled to retry. A newer attempt supersedes this one
            // naturally by claiming the next generation.
            MobileDebugLog.anchormux(
                "storedMacReconnect restoring gate resolved; dial continues generation=\(generation)"
            )
            self.finishStoredMacReconnectAttempt(generation: generation)
        }
        defer { restoringDeadline.cancel() }
        // Run the awaited restore/dial phase under the same hard ceiling for
        // startup, team changes, manual fallback, and automatic recovery. The
        // generation claim above remains synchronous, preserving serialization
        // while the unstructured operation can be abandoned if an FFI dial
        // ignores cancellation.
        let deadlineNanoseconds = runtime?.reconnectAttemptDeadlineNanoseconds
            ?? 30_000_000_000
        let race = await Self.raceAgainstDeadline(
            nanoseconds: deadlineNanoseconds
        ) { [weak self] in
            await self?.performReconnectActiveMacAttempt(
                stackUserID: stackUserID,
                refreshBackupBeforeDial: refreshBackupBeforeDial,
                generation: generation
            ) ?? .superseded
        }
        registerAbandonedReconnectDial(race.abandoned)
        if race.wasCancelled {
            finishStoredMacReconnectAttempt(generation: generation)
            return .superseded
        }
        if let outcome = race.value {
            if outcome.didConnect {
                // Start secondary dials only after the bounded foreground
                // operation has handed ownership back to this shared entry.
                // This preserves foreground-first ordering even though the
                // deadline race executes the awaited phase in a child task.
                scheduleSecondaryAggregation(discoverLivePeers: true)
            }
            if case .failed(let failure) = outcome {
                armAutomaticReconnectRetryAfterFailedAttempt(
                    failure: failure,
                    stackUserID: stackUserID
                )
            }
            return outcome
        }
        MobileDebugLog.anchormux(
            "storedMacReconnect deadline expired generation=\(generation)"
        )
        finishStoredMacReconnectAttempt(generation: generation)
        if Self.shouldRecordReconnectBackoff(
            abandonedDialCount: abandonedReconnectDialCount
        ),
           let accountID = stackUserID ?? identityProvider?.currentUserID {
            recordTransientAutomaticReconnectBackoff(accountID: accountID)
        }
        return .failed(.timedOut)
    }

    private func performReconnectActiveMacAttempt(
        stackUserID: String?,
        refreshBackupBeforeDial: Bool,
        generation: Int
    ) async -> StoredMacReconnectOutcome {
        // No store / not signed in: can't determine a stored Mac here. Resolve the
        // restoring gate (so a returning user doesn't spin on RestoringSessionView)
        // but leave the persisted hint intact for a future attempt.
        guard let pairedMacStore else {
            finishStoredMacReconnectAttempt(generation: generation)
            return .failed(.noRoute)
        }
        guard isSignedIn,
              let scope = await currentScopeSnapshot(userID: stackUserID) else {
            finishStoredMacReconnectAttempt(generation: generation)
            return .failed(.authorizationFailed)
        }
        if let result = storedMacReconnectInterruptionResult(generation: generation) {
            return result ? .connected : .superseded
        }
        // Pull the authoritative per-user backup first so saved-Mac routes are
        // current before we dial: a Mac that relaunched on a new port republishes
        // to the backup, and LWW by lastSeenAt keeps any live local edit. Without
        // this a stale port makes the auto-connect fail and the app falls back to
        // the Mac picker, the screen we want to avoid showing.
        if refreshBackupBeforeDial,
           let refresher = pairedMacStore as? any PairedMacBackupRefreshing {
            await refresher.refreshFromBackup(stackUserID: scope.userID)
        }
        if let result = storedMacReconnectInterruptionResult(generation: generation) {
            return result ? .connected : .superseded
        }
        guard await isScopeCurrent(scope) else {
            finishStoredMacReconnectAttempt(generation: generation)
            return .superseded
        }
        if let result = storedMacReconnectInterruptionResult(generation: generation) {
            return result ? .connected : .superseded
        }
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        func storedReconnectRoutes(_ mac: MobilePairedMac) -> [CmxAttachRoute] {
            orderedReconnectRoutes(for: mac, supportedKinds: supportedKinds)
        }
        let loadedActiveMac: MobilePairedMac?
        let loadedMacs: [MobilePairedMac]
        do {
            loadedActiveMac = try await pairedMacStore.activeMac(stackUserID: scope.userID, teamID: scope.teamID)
            if let result = storedMacReconnectInterruptionResult(generation: generation) {
                return result ? .connected : .superseded
            }
            loadedMacs = try await pairedMacStore.loadAll(stackUserID: scope.userID, teamID: scope.teamID)
        } catch {
            mobileShellLog.error("paired mac store read failed: \(String(describing: error), privacy: .public)")
            // A read failure means "couldn't determine," not "no mac": keep the
            // hint so a transient SQLite error doesn't erase a returning user's
            // paired state.
            finishStoredMacReconnectAttempt(generation: generation)
            return .failed(.unknown)
        }
        if let result = storedMacReconnectInterruptionResult(generation: generation) {
            return result ? .connected : .superseded
        }
        guard await isScopeCurrent(scope) else {
            finishStoredMacReconnectAttempt(generation: generation)
            return .superseded
        }
        if let result = storedMacReconnectInterruptionResult(generation: generation) {
            return result ? .connected : .superseded
        }
        let hiddenIDs = await hiddenMacDeviceIDs(scope: scope)
        if let result = storedMacReconnectInterruptionResult(generation: generation) {
            return result ? .connected : .superseded
        }
        guard await isScopeCurrent(scope) else {
            finishStoredMacReconnectAttempt(generation: generation)
            return .superseded
        }
        if let result = storedMacReconnectInterruptionResult(generation: generation) {
            return result ? .connected : .superseded
        }
        let isHidden: (MobilePairedMac) -> Bool = { mac in
            hiddenIDs.contains(mac.id)
                || (mac.instanceTag == nil && hiddenIDs.contains(mac.macDeviceID))
        }
        let activeMac = loadedActiveMac.flatMap { isHidden($0) ? nil : $0 }
        let allMacs = loadedMacs.filter { !isHidden($0) }
        // Candidate Macs in priority order: the active Mac first, then every
        // other saved Mac. Rows with no locally usable route stay in the list so
        // one authenticated registry snapshot can upgrade an older Tailscale
        // pairing, or recover a route that was never persisted locally.
        var candidates: [MobilePairedMac] = []
        if let activeMac {
            candidates.append(activeMac)
        }
        candidates.append(contentsOf: allMacs.filter { $0.id != activeMac?.id })
        // A newer attempt may have started while we awaited the store read; if so,
        // let it own the flags rather than marking ourselves the active reconnect.
        guard generation == storedMacReconnectGeneration else { return .superseded }
        let hasKnownStoredMac = loadedActiveMac != nil
            || !loadedMacs.isEmpty
            || !hiddenIDs.isEmpty
        if hasKnownStoredMac {
            setHasKnownPairedMac(true, generation: generation)
        }
        let tailscaleOnly = connectionMethodStore?.method == .tailscale
        let irohReconnectIsBlocked = tailscaleOnly
            || automaticIrohReconnectIsBlocked(accountID: scope.userID)
        // Capture one coherent post-request view of the registry and paired-Mac
        // store. The store read happens after the registry await, so an
        // authenticated Presence write that lands during the request wins. The
        // immutable indexes are then reused for every candidate, keeping this
        // reconnect pass linear and on one authority generation.
        var didLoadRefreshSnapshot = false
        var refreshSnapshot: ReconnectRefreshSnapshot?
        func loadRefreshSnapshotIfNeeded() async -> ReconnectRefreshSnapshot? {
            if didLoadRefreshSnapshot { return refreshSnapshot }
            didLoadRefreshSnapshot = true
            refreshSnapshot = await loadReconnectRefreshSnapshot(scope: scope)
            return refreshSnapshot
        }

        var firstCandidateNeedingMacUpdate: MobilePairedMac?
        var attemptedAutomaticIroh = false
        var lastDialOutcome: StoredMacReconnectOutcome = .failed(.noRoute)
        // Try each candidate until one connects, so a single offline Mac never
        // blocks the others.
        for (candidateIndex, mac) in candidates.enumerated() {
            guard generation == storedMacReconnectGeneration,
                  await isScopeCurrent(scope) else { break }
            guard generation == storedMacReconnectGeneration,
                  await isScopeCurrent(scope),
                  await !isHiddenMacDeviceID(
                      mac.macDeviceID,
                      instanceTag: mac.instanceTag,
                      scope: scope
                  ) else { break }
            // Tailscale Only blocks the Iroh lane only for legacy pairings
            // without an Iroh identity; an identified pairing rides Iroh
            // pinned to its Tailscale addresses (same lane the terminal
            // lanes ride, same admission authority).
            let irohReconnectIsBlocked = (connectionMethod(for: mac) == .tailscale
                && !mac.routes.contains { $0.kind == .iroh })
                || automaticIrohReconnectIsBlocked(accountID: scope.userID)
            let localRoutes = storedReconnectRoutes(mac).filter {
                !irohReconnectIsBlocked || $0.kind != .iroh
            }
            let localHasIroh = localRoutes.contains { $0.kind == .iroh }
            let localCanConnectSecurely = localHasIroh
                || localRoutes.contains { $0.kind == .debugLoopback }
                || localRoutes.contains { route in
                    Self.legacyTailscaleAuthorizationEvidence(
                        for: route,
                        macDeviceID: mac.macDeviceID,
                        persistedRoutes: mac.legacyTailscaleRoutes ?? []
                    ) != nil
                }
            let isLegacyPrivateNetworkPairing = !mac.routes.contains { $0.kind == .iroh }
                && mac.routes.contains { $0.kind == .tailscale }

            // Raw Tailscale/TCP is bearer-capable only for an exact local route
            // grandfathered during the v7-to-v8 migration. Every fresh, changed,
            // restored, or registry route remains a hint for discovering Iroh.
            if localCanConnectSecurely {
                attemptedAutomaticIroh = attemptedAutomaticIroh || localHasIroh
                lastDialOutcome = await connectStoredMacOutcome(
                    name: mac.displayName ?? mac.macDeviceID,
                    routes: localRoutes,
                    pairedMacDeviceID: mac.macDeviceID,
                    instanceTag: mac.instanceTag,
                    legacyTailscaleRoutes: mac.legacyTailscaleRoutes ?? [],
                    automaticReconnectAccountID: scope.userID,
                    knownPairing: mac,
                    ifStillCurrent: { [weak self] in
                        self?.storedMacReconnectGeneration == generation
                    }
                )
            }
            if connectionState != .connected, !tailscaleOnly,
               !automaticIrohReconnectIsBlocked(accountID: scope.userID) {
                switch await freshReconnectRoutesAfterLocalFailure(
                    for: mac,
                    scope: scope,
                    snapshot: await loadRefreshSnapshotIfNeeded()
                ) {
                case .refreshedRoutes(let refreshedRoutes):
                    attemptedAutomaticIroh = attemptedAutomaticIroh
                        || refreshedRoutes.contains { $0.kind == .iroh }
                    lastDialOutcome = await connectStoredMacOutcome(
                        name: mac.displayName ?? mac.macDeviceID,
                        routes: refreshedRoutes,
                        pairedMacDeviceID: mac.macDeviceID,
                        instanceTag: mac.instanceTag,
                        legacyTailscaleRoutes: mac.legacyTailscaleRoutes ?? [],
                        automaticReconnectAccountID: scope.userID,
                        knownPairing: mac,
                        ifStillCurrent: { [weak self] in
                            self?.storedMacReconnectGeneration == generation
                        }
                    )
                case .confirmedMissingIroh:
                    lastDialOutcome = .failed(.unsupportedRoute)
                    if isLegacyPrivateNetworkPairing,
                       candidateIndex == candidates.startIndex {
                        firstCandidateNeedingMacUpdate = mac
                    }
                case .inconclusive:
                    break
                }
            }
            if connectionState == .connected { break }
        }
        // A saved authenticated route is the cheapest and most authoritative
        // recovery path. Broker discovery can be slow for accounts with a large
        // development fleet, so only ask for zero-touch candidates after every
        // saved candidate failed. This keeps a healthy saved Mac from sitting
        // behind an unrelated account-wide discovery request.
        var zeroTouchCandidates: [MobilePairedMac] = []
        if connectionState != .connected, !tailscaleOnly,
           !automaticIrohReconnectIsBlocked(accountID: scope.userID) {
            zeroTouchCandidates = await discoverZeroTouchIrohCandidates(
                scope: scope,
                generation: generation,
                excluding: Set(candidates.map {
                    MobilePairedMac.pairingID(
                        macDeviceID: $0.macDeviceID,
                        instanceTag: $0.instanceTag
                    )
                })
            )
            guard generation == storedMacReconnectGeneration else {
                return .superseded
            }
            guard await isScopeCurrent(scope) else {
                finishStoredMacReconnectAttempt(generation: generation)
                return .superseded
            }
            for mac in zeroTouchCandidates {
                guard generation == storedMacReconnectGeneration,
                      await isScopeCurrent(scope),
                      await !isHiddenMacDeviceID(
                          mac.macDeviceID,
                          instanceTag: mac.instanceTag,
                          scope: scope
                      ) else { break }
                let routes = storedReconnectRoutes(mac)
                attemptedAutomaticIroh = attemptedAutomaticIroh
                    || routes.contains { $0.kind == .iroh }
                lastDialOutcome = await connectStoredMacOutcome(
                    name: mac.displayName ?? mac.macDeviceID,
                    routes: routes,
                    pairedMacDeviceID: mac.macDeviceID,
                    instanceTag: mac.instanceTag,
                    legacyTailscaleRoutes: mac.legacyTailscaleRoutes ?? [],
                    automaticReconnectAccountID: scope.userID,
                    knownPairing: mac,
                    ifStillCurrent: { [weak self] in
                        self?.storedMacReconnectGeneration == generation
                    }
                )
                if connectionState == .connected { break }
            }
        }
        if candidates.isEmpty, zeroTouchCandidates.isEmpty {
            if !hasKnownStoredMac, !irohReconnectIsBlocked {
                setHasKnownPairedMac(false, generation: generation)
            }
            finishStoredMacReconnectAttempt(generation: generation)
            return .failed(.noRoute)
        }
        // A newer attempt may have started during the connect; it now owns the flags.
        guard generation == storedMacReconnectGeneration else { return .superseded }
        guard await isScopeCurrent(scope) else {
            finishStoredMacReconnectAttempt(generation: generation)
            return .superseded
        }
        finishStoredMacReconnectAttempt(generation: generation)
        if connectionState != .connected,
           !connectionRequiresReauth,
           let firstCandidateNeedingMacUpdate {
            let isStillLegacy = await isCurrentLegacyPrivateNetworkPairing(
                firstCandidateNeedingMacUpdate,
                scope: scope
            )
            if generation == storedMacReconnectGeneration,
               await isScopeCurrent(scope),
               connectionState != .connected,
               !connectionRequiresReauth,
               isStillLegacy,
               await !isHiddenMacDeviceID(
                   firstCandidateNeedingMacUpdate.macDeviceID,
                   instanceTag: firstCandidateNeedingMacUpdate.instanceTag,
                   scope: scope
               ) {
                applyStoredMacUpdateRequiredFailure(disconnect: true)
                lastDialOutcome = .failed(.unsupportedRoute)
            }
        }
        if connectionState != .connected,
           !connectionRequiresReauth,
           attemptedAutomaticIroh {
            recordTransientAutomaticReconnectBackoff(accountID: scope.userID)
        }
        return connectionState == .connected ? .connected : lastDialOutcome
    }

    // MARK: - Paired Mac switching

    /// Whether the current signed-in scope's paired-Mac list is known.
    public enum PairedMacLoadState: Equatable, Sendable {
        /// No load has completed for the current scope.
        case notLoaded
        /// The current scope's paired-Mac list loaded successfully.
        case loaded
        /// The current scope's paired-Mac list could not be loaded.
        case failed
    }

    /// Every Mac paired with this device, for the host switcher. Refreshed via
    /// ``loadPairedMacs()`` and after switch/hide. Cleared on sign-out so a
    /// shared device never shows the previous user's Macs. The active row is
    /// marked by each ``MobilePairedMac/isActive`` flag (the live connection's
    /// attach ticket carries a transient manual id, so it is not a reliable
    /// active marker on its own).
    public private(set) var pairedMacs: [MobilePairedMac] = [] {
        didSet {
            // The derived workspace list reads pairedMacs (Last Opened
            // recency, per-Mac customization stamping), so a pairing refresh
            // must rebuild it or the aggregate order goes stale until the next
            // workspace event.
            if oldValue != pairedMacs {
                recomputeDerivedWorkspaceState()
            }
            guard oldValue.count != pairedMacs.count else { return }
            analytics.setSuperProperties(["paired_mac_count": .int(pairedMacs.count)])
        }
    }

    /// Visible store rows for identity-sensitive paths; ``pairedMacs`` is display-coalesced.
    private var storedPairedMacs: [MobilePairedMac] = []
    /// Every scoped SQLite row, including hidden rows, for route refresh and hidden presentation.
    @ObservationIgnored var storedPairedMacsIncludingHidden: [MobilePairedMac] = [] {
        didSet {
            hasStoredUsableTailscaleAuthorization = Self
                .hasUsableTailscaleAuthorization(in: storedPairedMacsIncludingHidden)
        }
    }
    /// Cached local Tailscale readiness for the current paired-Mac snapshot.
    var hasStoredUsableTailscaleAuthorization = false
    /// Load status for ``pairedMacs`` in the current signed-in account/team scope.
    public internal(set) var pairedMacLoadState: PairedMacLoadState = .notLoaded
    /// Visible representative id to all stored ids for that logical paired Mac.
    public private(set) var pairedMacAliasIDsByRepresentativeID: [String: [String]] = [:]
    /// Cached device-local hidden ids keyed by signed-in account/team scope.
    @ObservationIgnored var hiddenMacDeviceIDsByScope: [String: Set<String>] = [:]
    /// Row-backed hidden entries for the current account/team.
    public internal(set) var hiddenComputers: [MobileHiddenComputer] = []
    /// True when the current account/team scope has at least one hidden computer.
    public internal(set) var hasHiddenComputers = false
    /// Computer identities whose visibility preference is being persisted.
    public internal(set) var computerVisibilityMutationIDs: Set<String> = []
    @ObservationIgnored var computerVisibilityMutationTasksByID: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var computerVisibilityMutationOperationIDsByID: [String: UUID] = [:]

    var pairedMacsForIdentityMatching: [MobilePairedMac] {
        storedPairedMacs.isEmpty ? pairedMacs : storedPairedMacs
    }

    private func installStoredPairedMacCache(
        _ macs: [MobilePairedMac],
        scope: MobileShellScopeSnapshot
    ) {
        storedPairedMacsIncludingHidden = macs
        storedPairedMacsByCanonicalDeviceID = Dictionary(
            grouping: macs,
            by: { cmxCanonicalDeviceID($0.macDeviceID) }
        )
        let aliasesByPairingID = physicalMacAliasCanonicalIDsByCanonicalID(
            in: macs,
            supportedKinds: runtime?.supportedRouteKinds ?? [],
            preferNonLoopback: Self.prefersNonLoopbackRoutes
        )
        storedPairedMacAliasCanonicalIDsByCanonicalID = aliasesByPairingID
        storedPairedMacAliasCanonicalIDsByDeviceID = aliasesByPairingID.reduce(
            into: [:]
        ) { result, entry in
            let identity = MobilePairedMac.pairingIdentity(from: entry.key)
            let canonicalDeviceID = cmxCanonicalDeviceID(identity.macDeviceID)
            result[canonicalDeviceID, default: []].formUnion(entry.value)
        }
        storedPairedMacCacheScope = scope
    }

    private func clearStoredPairedMacCache() {
        storedPairedMacsIncludingHidden = []
        storedPairedMacsByCanonicalDeviceID = [:]
        storedPairedMacAliasCanonicalIDsByCanonicalID = [:]
        storedPairedMacAliasCanonicalIDsByDeviceID = [:]
        storedPairedMacCacheScope = nil
    }

    private func expandedStoredAliasCanonicalIDs(
        _ canonicalIDs: Set<String>,
        scope: MobileShellScopeSnapshot
    ) -> Set<String>? {
        guard storedPairedMacCacheScope == scope else { return nil }
        var expanded = canonicalIDs
        for canonicalID in canonicalIDs {
            expanded.formUnion(
                storedPairedMacAliasCanonicalIDsByDeviceID[canonicalID] ?? []
            )
        }
        return expanded
    }

    /// Return only rows that can affect one targeted pool decision: the
    /// requested physical Macs, current control owners, and current foreground
    /// owner. That bounded context still detects endpoint aliases and a full
    /// pool, without an account-wide scan or sort.
    private func targetedStoredPairedMacs(
        requestedCanonicalIDs: Set<String>,
        scope: MobileShellScopeSnapshot
    ) -> [MobilePairedMac]? {
        guard storedPairedMacCacheScope == scope else { return nil }
        var relevantIDs = requestedCanonicalIDs
        relevantIDs.formUnion(
            secondaryMacSubscriptions.keys.map(\.canonicalMacDeviceID)
        )
        if let foregroundMacDeviceID {
            relevantIDs.insert(cmxCanonicalDeviceID(foregroundMacDeviceID))
        }
        for canonicalID in Array(relevantIDs) {
            relevantIDs.formUnion(
                storedPairedMacAliasCanonicalIDsByDeviceID[canonicalID] ?? []
            )
        }
        return relevantIDs.flatMap {
            storedPairedMacsByCanonicalDeviceID[$0] ?? []
        }
    }

    private func cachedStoredPairedMac(
        macDeviceID: String,
        instanceTag: String?,
        scope: MobileShellScopeSnapshot
    ) -> MobilePairedMac? {
        guard storedPairedMacCacheScope == scope else { return nil }
        return storedPairedMacsByCanonicalDeviceID[
            cmxCanonicalDeviceID(macDeviceID)
        ]?.first {
            MacPairingKey($0) == MacPairingKey(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag
            )
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
    public internal(set) var registryDevices: [RegistryDevice] = []

    /// The cmux device id of the Mac the live connection currently targets, or
    /// `nil` when not connected. Used by the device tree to mark which device row
    /// is live.
    ///
    /// Prefers the active attach ticket's real `macDeviceID`. A manual (`manual-…`)
    /// ticket has no real device id (the host lacks `mobile.attach_ticket.create`,
    /// so the connect synthesizes a manual ticket even on success); in that case,
    /// fall back to the live foreground id stamped by switch/reconnect paths before
    /// using the persisted active row. This keeps the connected device — and its
    /// live workspaces — visible even while the active-row write is still settling.
    /// Yields `nil` only when there is genuinely no real device id to correlate.
    public var connectedMacDeviceID: String? {
        guard connectionState == .connected else { return nil }
        if let macDeviceID = activeTicket?.macDeviceID,
           !macDeviceID.isEmpty,
           !macDeviceID.hasPrefix("manual-") {
            return macDeviceID
        }
        if let foregroundMacID = foregroundMacDeviceID,
           !foregroundMacID.isEmpty,
           !foregroundMacID.hasPrefix("manual-") {
            return foregroundMacID
        }
        // Manual/synthetic ticket but a live connection without a foreground id:
        // correlate via the active paired Mac the connect path persisted.
        if let activeMacID = pairedMacs.first(where: { $0.isActive })?.macDeviceID,
           !activeMacID.isEmpty,
           !activeMacID.hasPrefix("manual-") {
            return activeMacID
        }
        return nil
    }

    /// Authenticated app-instance tag for the live foreground Mac.
    public var connectedMacInstanceTag: String? {
        guard connectionState == .connected else { return nil }
        return activeMacInstanceTag
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
        let startedAt = appDiagnosticNow()
        recordAppEvent(.deviceRegistryLoadStarted)
        guard let deviceRegistry,
              let scope = await currentScopeSnapshot() else {
            registryDevices = []
            recordAppEvent(
                .deviceRegistryLoadFailed,
                startedAt: startedAt,
                failure: .authorizationFailed
            )
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
            recordAppEvent(
                .deviceRegistryLoadFailed,
                startedAt: startedAt,
                failure: .authorizationFailed
            )
            return
        case .transientFailure:
            // Network blip / 5xx / malformed body: keep what we have rather than
            // blanking a populated tree on a transient failure.
            recordAppEvent(
                .deviceRegistryLoadFailed,
                startedAt: startedAt,
                failure: .connectionClosed
            )
            return
        }
        // The await above suspended the main actor; discard the result unless we
        // are still in the same signed-in account/team scope, so a slow load can
        // never repopulate another scope's devices after sign-out, account switch,
        // or same-account team switch.
        guard await isScopeCurrent(scope) else { return }
        let connectedID = connectedMacDeviceID
        let hiddenIDs = await hiddenMacDeviceIDs(scope: scope)
        guard await isScopeCurrent(scope) else { return }
        let compatible = compatibleRegistryDevices(loaded)
        registryDevices = compatible
            .compactMap { device in
                var device = device
                device.instances = device.instances.filter { instance in
                    !hiddenIDs.contains(MobilePairedMac.pairingID(
                        macDeviceID: device.deviceId,
                        instanceTag: instance.tag
                    ))
                }
                return device.instances.isEmpty ? nil : device
            }
            .sorted { lhs, rhs in
            let lhsConnected = lhs.deviceId == connectedID
            let rhsConnected = rhs.deviceId == connectedID
            if lhsConnected != rhsConnected { return lhsConnected }
            return lhs.lastSeenAt > rhs.lastSeenAt
        }
        recordAppEvent(
            .deviceRegistryLoadSucceeded,
            startedAt: startedAt,
            count: registryDevices.count
        )
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
    func evaluatePresenceSubscription() {
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
        recordAppEvent(.presenceStreamStarted)
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
                    self?.recordAppEvent(
                        .presenceStreamFailed,
                        failure: DiagnosticFailureKind.classify(error)
                    )
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
        guard let update = compatiblePresenceUpdate(update) else { return }
        presenceMap.apply(update)
        recordAppEvent(
            .presenceStreamUpdated,
            count: presenceMap.instanceCount
        )
        let pushedRouteSyncTask: Task<Void, Never>?
        switch update {
        case .routes(let instance), .online(let instance):
            // Both events can carry fresh attach routes (online = a host that
            // re-announced after moving networks while the phone was watching).
            pushedRouteSyncTask = syncPushedRoutes(
                from: instance,
                scope: scope
            )
        case .snapshot(let snapshot):
            // The snapshot is the reconcile-on-(re)subscribe path: a port that
            // changed while the phone was offline lands here. One batch (not
            // one task per instance) so a multi-tag Mac syncs routes in
            // deterministic order and kicks at most one reconnect.
            pushedRouteSyncTask = syncPushedRoutes(
                from: snapshot.devices.flatMap { device in
                    device.instances.filter(\.online)
                },
                scope: scope
            )
        case .offline, .seen:
            pushedRouteSyncTask = nil
        }
        // Presence is the pool's membership authority. Reconcile on every
        // online/offline/snapshot/routes transition so offline Macs stop
        // consuming battery and newly online Macs are warmed immediately.
        if presence != nil {
            switch update {
            case .seen:
                break
            case .snapshot:
                scheduleSecondaryAggregationAfterPushedRoutes(
                    pushedRouteSyncTask,
                    macDeviceID: nil,
                    scope: scope
                )
            case .online(let instance), .routes(let instance):
                scheduleSecondaryAggregationAfterPushedRoutes(
                    pushedRouteSyncTask,
                    macDeviceID: instance.deviceId,
                    scope: scope
                )
            case .offline(let instance, _):
                scheduleSecondaryPresenceAggregation(
                    forMacDeviceID: instance.deviceId
                )
            }
        }
    }

    private func scheduleSecondaryAggregationAfterPushedRoutes(
        _ pushedRouteSyncTask: Task<Void, Never>?,
        macDeviceID: String?,
        scope: MobileShellScopeSnapshot
    ) {
        guard let pushedRouteSyncTask else {
            if let macDeviceID {
                scheduleSecondaryPresenceAggregation(
                    forMacDeviceID: macDeviceID
                )
            } else {
                scheduleSecondaryAggregation()
            }
            return
        }
        if let pendingScope = secondaryAggregationAfterPushedRoutesScope,
           pendingScope != scope {
            secondaryAggregationAfterPushedRoutesOperationID = UUID()
            secondaryAggregationAfterPushedRoutesTask?.cancel()
            secondaryAggregationAfterPushedRoutesTask = nil
            secondaryAggregationAfterPushedRoutesMacIDs = []
            secondaryAggregationAfterPushedRoutesNeedsFullRefresh = false
        }
        secondaryAggregationAfterPushedRoutesScope = scope
        if let macDeviceID {
            secondaryAggregationAfterPushedRoutesMacIDs.insert(
                cmxCanonicalDeviceID(macDeviceID)
            )
        } else {
            secondaryAggregationAfterPushedRoutesNeedsFullRefresh = true
        }
        guard secondaryAggregationAfterPushedRoutesTask == nil else { return }
        let operationID = UUID()
        secondaryAggregationAfterPushedRoutesOperationID = operationID
        secondaryAggregationAfterPushedRoutesTask =
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if self.secondaryAggregationAfterPushedRoutesOperationID
                        == operationID {
                        self.secondaryAggregationAfterPushedRoutesTask = nil
                        self.secondaryAggregationAfterPushedRoutesOperationID =
                            nil
                        self.secondaryAggregationAfterPushedRoutesScope = nil
                        self.secondaryAggregationAfterPushedRoutesMacIDs = []
                        self.secondaryAggregationAfterPushedRoutesNeedsFullRefresh =
                            false
                    }
                }
                while !Task.isCancelled {
                    let routeSyncOperationID =
                        self.pushedRouteSyncOperationID
                    let routeSyncTask = self.pushedRouteSyncTask
                        ?? pushedRouteSyncTask
                    await routeSyncTask.value
                    guard !Task.isCancelled else { return }
                    guard await self.isScopeCurrent(scope),
                          self.presence != nil else {
                        return
                    }
                    // The scope check suspends. Drain any route operation that
                    // started meanwhile before consuming the shared pending Mac
                    // IDs, or its new edge would be cleared by this waiter's
                    // defer before the new routes became authoritative.
                    if let currentRouteSyncOperationID =
                        self.pushedRouteSyncOperationID,
                       currentRouteSyncOperationID != routeSyncOperationID {
                        continue
                    }
                    break
                }
                let needsFullRefresh =
                    self.secondaryAggregationAfterPushedRoutesNeedsFullRefresh
                let macDeviceIDs =
                    self.secondaryAggregationAfterPushedRoutesMacIDs
                if needsFullRefresh {
                    self.scheduleSecondaryAggregation()
                } else {
                    for macDeviceID in macDeviceIDs {
                        self.scheduleSecondaryPresenceAggregation(
                            forMacDeviceID: macDeviceID
                        )
                    }
                }
            }
    }

    /// Reload ``pairedMacs`` from the store, scoped to the signed-in Stack user.
    ///
    /// A missing current Stack user id yields no pairings rather than falling
    /// back to the unscoped all-users query, so a shared device never exposes
    /// another user's Macs in the switcher.
    public func loadPairedMacs() async {
        let startedAt = appDiagnosticNow()
        recordAppEvent(.computerListRefreshStarted)
        guard let pairedMacStore,
              let scope = await currentScopeSnapshot() else {
            storedPairedMacs = []
            clearStoredPairedMacCache()
            pairedMacAliasIDsByRepresentativeID = [:]
            pairedMacs = []
            pairedMacLoadState = .failed
            hiddenComputers = []
            hasHiddenComputers = false
            recordAppEvent(
                .computerListRefreshFailed,
                startedAt: startedAt,
                failure: .authorizationFailed
            )
            return
        }
        pairedMacLoadState = .notLoaded
        let loaded: [MobilePairedMac]
        do {
            loaded = try await pairedMacStore.loadAll(stackUserID: scope.userID, teamID: scope.teamID)
        } catch {
            mobileShellLog.error("paired mac store loadAll failed: \(String(describing: error), privacy: .public)")
            if await isScopeCurrent(scope) {
                pairedMacLoadState = .failed
                hiddenComputers = []
                hasHiddenComputers = false
            }
            recordAppEvent(
                .computerListRefreshFailed,
                startedAt: startedAt,
                failure: DiagnosticFailureKind.classify(error)
            )
            recordAppEvent(
                .pairedMacStoreReadFailed,
                startedAt: startedAt,
                failure: DiagnosticFailureKind.classify(error)
            )
            return
        }
        // The await above suspended the main actor; a sign-out, user switch, or
        // same-account team switch may have run meanwhile. Discard unless the
        // captured account/team scope is still current.
        guard await isScopeCurrent(scope) else {
            return
        }
        migrateLegacyWorkspaceComputerPriority(loadedMacs: loaded)
        let storedHiddenIDs = await hiddenMacDeviceIDs(scope: scope)
        let hiddenIDs = await migrateLegacyHiddenMacMarkers(
            loadedMacs: loaded,
            hiddenIDs: storedHiddenIDs,
            scope: scope
        )
        let visibleLoaded = visibleStoredPairedMacs(
            from: loaded,
            hiddenIDs: hiddenIDs
        )
        guard await isScopeCurrent(scope) else {
            return
        }
        installStoredPairedMacCache(loaded, scope: scope)
        updateHiddenComputers(loadedMacs: loaded, hiddenIDs: hiddenIDs)
        if hasHiddenComputers, !hasKnownPairedMac {
            // Self-heal installs where an older build cleared the persisted hint
            // after hiding the final visible Mac. Hidden markers still represent
            // stored paired Macs, even when no row is currently visible.
            hasKnownPairedMac = true
        }
        pairedMacLoadState = .loaded
        storedPairedMacs = visibleLoaded
        let supportedRouteKinds = runtime?.supportedRouteKinds ?? []
        let coalesced = Self.coalescePairedMacsByDialEndpoint(
            visibleLoaded,
            supportedKinds: supportedRouteKinds,
            preferNonLoopback: Self.prefersNonLoopbackRoutes
        )
        let aliasIDsByPairingID = macDeviceIDAliasesByPairedMacID(
            in: visibleLoaded,
            supportedKinds: supportedRouteKinds,
            preferNonLoopback: Self.prefersNonLoopbackRoutes
        )
        pairedMacAliasIDsByRepresentativeID = coalesced.reduce(into: [String: [String]]()) { result, mac in
            result[mac.id] = aliasIDsByPairingID[mac.id] ?? [mac.macDeviceID]
        }
        pairedMacs = visibleLoaded
        recordAppEvent(
            .pairedMacStoreReadSucceeded,
            startedAt: startedAt,
            count: loaded.count
        )
        recordAppEvent(
            .computerListRefreshSucceeded,
            startedAt: startedAt,
            count: visibleLoaded.count
        )
    }

    /// Switch the live connection to `macDeviceID`, persisting it as the active
    /// pairing only on a successful connect.
    ///
    /// The underlying connect path is destructive (it replaces the live client),
    /// so a failed switch to an offline/stale Mac would drop the working session.
    /// To avoid stranding the user, the store's active row is only updated on a
    /// successful connect, and on failure the previously-active Mac (still the
    /// active row) is reconnected. A no-op when already connected to that Mac.
    /// - Parameters:
    ///   - macDeviceID: The stored physical Mac to switch to.
    ///   - instanceTag: Exact saved app instance to switch to, or `nil` for
    ///     legacy device-level routing.
    /// - Returns: `true` if the foreground connection now targets that Mac (or
    ///   already did), `false` if the switch could not connect — so callers like
    ///   `openWorkspace` can avoid selecting a workspace whose Mac is not live.
    /// Switch the foreground connection to another paired Mac.
    @discardableResult
    public func switchToMac(
        macDeviceID: String,
        instanceTag: String? = nil
    ) async -> Bool {
        let startedAt = appDiagnosticNow()
        recordAppEvent(.computerSelected, correlationID: macDeviceID)
        recordAppEvent(.computerSwitchStarted, correlationID: macDeviceID)
        guard let pairedMacStore else {
            recordAppEvent(
                .computerSwitchFailed,
                correlationID: macDeviceID,
                startedAt: startedAt,
                failure: .endpointUnavailable
            )
            return false
        }
        let switchAttemptID = beginMacSwitchAttempt()
        let liveForegroundRestoreBaseline = liveForegroundMacForSwitchRestore()
        let switched = await withTaskCancellationHandler {
            guard !Task.isCancelled else {
                await restoreMacSwitchBaselineIfCancelled(switchAttemptID)
                return false
            }
            return await performMacSwitch(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag,
                pairedMacStore: pairedMacStore,
                switchAttemptID: switchAttemptID,
                liveForegroundRestoreBaseline: liveForegroundRestoreBaseline
            )
        } onCancel: {
            Task { @MainActor [weak self] in _ = self?.cancelMacSwitchAttempt(switchAttemptID) }
        }
        recordAppEvent(
            switched ? .computerSwitchSucceeded : .computerSwitchFailed,
            correlationID: macDeviceID,
            startedAt: startedAt,
            failure: switched ? nil : (Task.isCancelled ? .cancelled : .connectionClosed)
        )
        return switched
    }

    private func performMacSwitch(
        macDeviceID: String,
        instanceTag: String?,
        pairedMacStore: any MobilePairedMacStoring,
        switchAttemptID: UUID,
        liveForegroundRestoreBaseline: MobilePairedMac?
    ) async -> Bool {
        defer { finishMacSwitchAttempt(switchAttemptID) }
        // Promotion becomes destructive before its final snapshot request.
        // Publish the live rollback target before entering that fast path so
        // cancellation can restore it from every post-handoff await.
        if let liveForegroundRestoreBaseline {
            macSwitchRestoreBaseline = liveForegroundRestoreBaseline
        }
        // FAST PATH: if a live read-only connection to this Mac already exists,
        // promote it to the foreground (reuse the client) instead of re-dialing.
        if let promotableOwnerKey = resolvePromotableSecondaryOwnerKey(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        ) {
            if await warmIrohFocusCandidateIsAuthorized(promotableOwnerKey),
               focusWarmIrohPeer(
                promotableOwnerKey,
                switchAttemptID: switchAttemptID
               ) {
                macSwitchRestoreBaseline = nil
                return true
            }
            switch await promoteSecondaryToForegroundOutcome(
                promotableOwnerKey,
                switchAttemptID: switchAttemptID
            ) {
            case .promoted:
                macSwitchRestoreBaseline = nil
                return true
            case .transientFailure:
                return false
            case .unavailable:
                break
            }
        }
        guard isCurrentMacSwitchAttempt(switchAttemptID) else {
            await restoreMacSwitchBaselineIfCancelled(switchAttemptID)
            return false
        }
        // Refresh routes from the per-user backup so a Mac that relaunched on a
        // new port is reachable — the same freshness guarantee auto-connect and
        // aggregation use — then resolve the target from the STORE (authoritative).
        // The multi-Mac aggregation reads Macs straight from the store and can
        // surface a Mac (a freshly restored secondary) that the in-memory
        // `pairedMacs` cache has not loaded yet; gating on that cache would no-op
        // the open and strand the user on a workspace whose Mac never connected.
        if let refresher = pairedMacStore as? any PairedMacBackupRefreshing {
            await refresher.refreshFromBackup(stackUserID: identityProvider?.currentUserID)
            guard isCurrentMacSwitchAttempt(switchAttemptID) else {
                await restoreMacSwitchBaselineIfCancelled(switchAttemptID)
                return false
            }
        }
        let scope = await currentScopeSnapshot()
        guard isCurrentMacSwitchAttempt(switchAttemptID) else {
            await restoreMacSwitchBaselineIfCancelled(switchAttemptID)
            return false
        }
        let storeMacs = (try? await pairedMacStore.loadAll(
            stackUserID: scope?.userID ?? identityProvider?.currentUserID,
            teamID: scope?.teamID
        )) ?? []
        guard isCurrentMacSwitchAttempt(switchAttemptID) else {
            await restoreMacSwitchBaselineIfCancelled(switchAttemptID)
            return false
        }
        let matchesTarget: (MobilePairedMac) -> Bool = { mac in
            MacPairingKey(mac) == MacPairingKey(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag
            )
        }
        let targetMatches = storeMacs.filter(matchesTarget)
        // A device-only request against MULTIPLE stored sibling builds is
        // ambiguous: the store orders by recency, not build authority, so
        // dialing `first` could disconnect the current focus in favor of an
        // arbitrary sibling. Fail the switch; pairing-aware callers pass the
        // tag, and legacy device-only entry points must not guess.
        if instanceTag == nil,
           Set(targetMatches.map(MacPairingKey.init)).count > 1 {
            mobileShellLog.error(
                "switchToMac: device-only request is ambiguous across stored sibling builds mac=\(macDeviceID, privacy: .public)"
            )
            return false
        }
        guard let refreshedTarget = targetMatches.first else {
            if !hasActiveMacConnection,
               await restorePreviousMacIfNeeded(macSwitchRestoreBaseline, switchAttemptID: switchAttemptID) {
                macSwitchRestoreBaseline = nil
            }
            return false
        }
        // Already foreground on this exact Mac: skip the re-dial. Gate on the LIVE
        // foreground identity, not the persisted `isActive` flag — `isActive` is
        // stored preference state that can lag the real connection (e.g.
        // `promoteSecondaryToForeground` writes it via an unawaited Task, and it is
        // stale during reconnect/switch races). Trusting it could make `openWorkspace`
        // proceed without switching and route input/mutations to the wrong Mac.
        if let foregroundMacDeviceID,
           MacPairingKey(
               macDeviceID: foregroundMacDeviceID,
               instanceTag: activeMacInstanceTag
           ) == MacPairingKey(refreshedTarget),
           connectionState == .connected,
           remoteClient != nil {
            macSwitchRestoreBaseline = nil
            return true
        }
        // The LIVE foreground Mac to fall back to if the destructive switch fails.
        // Persisted `isActive` can lag the connection, so use the foreground id
        // captured before `connectManualHost` clears/replaces the live context.
        let previousForegroundMacDeviceID = foregroundMacDeviceID
        let previousForegroundMac = liveForegroundRestoreBaseline
            ?? previousForegroundMacForSwitchRestore(
                previousForegroundMacDeviceID: previousForegroundMacDeviceID,
                previousForegroundInstanceTag: activeMacInstanceTag,
                switchingTo: macDeviceID,
                switchingToInstanceTag: refreshedTarget.instanceTag,
                storeMacs: storeMacs
            )
        if let previousForegroundMac {
            macSwitchRestoreBaseline = previousForegroundMac
        } else if hasActiveMacConnection {
            macSwitchRestoreBaseline = nil
        }
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        let candidateRoutes = orderedReconnectRoutes(
            for: refreshedTarget,
            supportedKinds: supportedKinds
        )
        let localHasIroh = candidateRoutes.contains { $0.kind == .iroh }
        let localCanConnectSecurely = localHasIroh
            || candidateRoutes.contains { $0.kind == .debugLoopback }
            || candidateRoutes.contains { route in
                Self.legacyTailscaleAuthorizationEvidence(
                    for: route,
                    macDeviceID: refreshedTarget.macDeviceID,
                    persistedRoutes: refreshedTarget.legacyTailscaleRoutes ?? []
                ) != nil
            }
        let isLegacyPrivateNetworkPairing = !refreshedTarget.routes.contains { $0.kind == .iroh }
            && refreshedTarget.routes.contains { $0.kind == .tailscale }
        var refreshOutcome = ReconnectRouteRefreshOutcome.inconclusive

        if localCanConnectSecurely {
            _ = await connectStoredMac(
                name: refreshedTarget.displayName ?? macDeviceID,
                routes: candidateRoutes,
                pairedMacDeviceID: macDeviceID,
                instanceTag: refreshedTarget.instanceTag,
                legacyTailscaleRoutes: refreshedTarget.legacyTailscaleRoutes ?? [],
                recordsPairingAttempt: true,
                ifStillCurrent: { [weak self] in
                    self?.isCurrentMacSwitchAttempt(switchAttemptID) == true
                }
            )
        }
        guard isCurrentMacSwitchAttempt(switchAttemptID) else {
            await restoreMacSwitchBaselineIfCancelled(switchAttemptID, fallback: previousForegroundMac)
            return false
        }

        var switched = connectionState == .connected
            && remoteClient != nil
            && MacPairingKey(
                macDeviceID: foregroundMacDeviceID ?? "",
                instanceTag: activeMacInstanceTag
            ) == MacPairingKey(refreshedTarget)
        if !switched, let scope {
            refreshOutcome = await freshReconnectRoutesAfterLocalFailure(
                for: refreshedTarget,
                scope: scope,
                snapshot: await loadReconnectRefreshSnapshot(scope: scope)
            )
            if case .refreshedRoutes(let refreshedRoutes) = refreshOutcome {
                    _ = await connectStoredMac(
                        name: refreshedTarget.displayName ?? macDeviceID,
                        routes: refreshedRoutes,
                        pairedMacDeviceID: macDeviceID,
                        instanceTag: refreshedTarget.instanceTag,
                        legacyTailscaleRoutes: refreshedTarget.legacyTailscaleRoutes ?? [],
                        recordsPairingAttempt: true,
                        ifStillCurrent: { [weak self] in
                            self?.isCurrentMacSwitchAttempt(switchAttemptID) == true
                        }
                    )
            }
            guard isCurrentMacSwitchAttempt(switchAttemptID) else {
                await restoreMacSwitchBaselineIfCancelled(switchAttemptID, fallback: previousForegroundMac)
                return false
            }
            switched = connectionState == .connected
                && remoteClient != nil
                && MacPairingKey(
                    macDeviceID: foregroundMacDeviceID ?? "",
                    instanceTag: activeMacInstanceTag
                ) == MacPairingKey(refreshedTarget)
        }
        // The switch succeeded only if the live foreground identity is THIS Mac.
        // `connect(..., pairedMacDeviceID:)` stamps the foreground state with the
        // target id after a successful connection, while a superseding switch leaves
        // a different foreground id. Trust that identity instead of exact host/port
        // text equality, which can differ across normalized routes.
        if switched {
            macSwitchRestoreBaseline = nil
            finishMacSwitchAttempt(switchAttemptID)
            if let task = enqueueActivePairedMacWrite(
                macDeviceID: macDeviceID,
                instanceTag: refreshedTarget.instanceTag,
                scope: scope,
                reloadAfterWrite: true
            ) {
                await task.value
            }
            return connectionState == .connected
                && remoteClient != nil
                && foregroundMacDeviceID.map {
                    MacPairingKey(
                        macDeviceID: $0,
                        instanceTag: activeMacInstanceTag
                    ) == MacPairingKey(refreshedTarget)
                } == true
        } else if macSwitchRestoreBaseline != nil || previousForegroundMac != nil, !hasActiveMacConnection {
            // The switch did not connect and the destructive connect path dropped
            // the previous session; reconnect to the still-active previous Mac so
            // the user is not left stranded on a failed switch.
            // Keep the attempt alive through the restore so a rapid follow-up
            // picker selection can either cancel this rollback while preserving
            // its baseline, or replace it with a new live foreground baseline.
            let restoreTarget = macSwitchRestoreBaseline ?? previousForegroundMac
            if await restorePreviousMacIfNeeded(restoreTarget, switchAttemptID: switchAttemptID) {
                macSwitchRestoreBaseline = nil
            }
        }
        if isLegacyPrivateNetworkPairing,
           case .confirmedMissingIroh = refreshOutcome,
           let scope,
           isCurrentMacSwitchAttempt(switchAttemptID),
           await isScopeCurrent(scope) {
            let isStillLegacy = await isCurrentLegacyPrivateNetworkPairing(
                refreshedTarget,
                scope: scope
            )
            if isCurrentMacSwitchAttempt(switchAttemptID),
               await isScopeCurrent(scope),
               !connectionRequiresReauth,
               !(connectionState == .connected
                   && remoteClient != nil
                   && foregroundMacDeviceID.map {
                       MacPairingKey(
                           macDeviceID: $0,
                           instanceTag: activeMacInstanceTag
                       ) == MacPairingKey(refreshedTarget)
                   } == true),
               isStillLegacy,
               await !isHiddenMacDeviceID(
                   macDeviceID,
                   instanceTag: refreshedTarget.instanceTag,
                   scope: scope
               ) {
                applyStoredMacUpdateRequiredFailure(disconnect: !hasActiveMacConnection)
            }
        }
        await loadPairedMacs()
        return false
    }

    @discardableResult
    private func restorePreviousMacIfNeeded(
        _ previousActive: MobilePairedMac?,
        switchAttemptID: UUID? = nil,
        cancelRestoreGeneration: UInt64? = nil
    ) async -> Bool {
        func isRestoreCurrent() -> Bool {
            guard isSignedIn else { return false }
            if let switchAttemptID {
                return isCurrentMacSwitchAttempt(switchAttemptID)
            }
            guard let cancelRestoreGeneration else { return true }
            return macSwitchCancelRestoreGeneration == cancelRestoreGeneration
                && macSwitchAttemptID == nil
        }
        guard isRestoreCurrent() else { return false }
        guard let previousActive else { return false }
        guard let restoreScope = await currentScopeSnapshot() else { return false }
        guard await isScopeCurrent(restoreScope), isRestoreCurrent() else { return false }
        let previousIDs = Set(pairedMacAliasIDs(
            for: previousActive.macDeviceID,
            instanceTag: previousActive.instanceTag
        ))
        let focusedForegroundConnection = foregroundMacDeviceID.flatMap {
            connections[$0]
        }
        let foregroundHandoffNeedsRepair =
            focusedForegroundConnection == nil
            || focusedForegroundConnection.map {
                focusedHandoffPreparedGenerations.contains($0.generation)
            } == true
        let previousStillForeground = connectionState == .connected
            && remoteClient != nil
            && !foregroundHandoffNeedsRepair
            && focusedForegroundConnection?.client === remoteClient
            && foregroundMacDeviceID.map {
                MacPairingKey(
                    macDeviceID: $0,
                    instanceTag: activeMacInstanceTag
                ) == MacPairingKey(previousActive)
            } == true
        guard !previousStillForeground else { return true }
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        let candidateRoutes = orderedReconnectRoutes(
            for: previousActive,
            supportedKinds: supportedKinds
        )
        guard !candidateRoutes.isEmpty else {
            mobileShellLog.error("restorePreviousMacIfNeeded: no reconnectable route mac=\(previousActive.macDeviceID, privacy: .private)")
            return false
        }
        _ = await connectStoredMac(
            name: previousActive.displayName ?? previousActive.macDeviceID,
            routes: candidateRoutes,
            pairedMacDeviceID: previousActive.macDeviceID,
            instanceTag: previousActive.instanceTag,
            legacyTailscaleRoutes: previousActive.legacyTailscaleRoutes ?? [],
            ifStillCurrent: isRestoreCurrent
        )
        let restoreScopeIsCurrent = await isScopeCurrent(restoreScope)
        guard restoreScopeIsCurrent, isRestoreCurrent() else {
            if !restoreScopeIsCurrent,
               connectionState == .connected,
               remoteClient != nil,
               foregroundMacDeviceID.map({ previousIDs.contains($0) }) == true {
                suppressNextConnectionOutageEdge = true
                connectionState = .disconnected
                macConnectionStatus = .unavailable
                clearRemoteConnectionContext()
                workspacesByMac = workspacesByMac.filter { entry in
                    !(previousIDs.contains(where: { entry.key.isOnDevice($0) })
                        && macInstanceTagAuthority.sameStoredAuthority(
                            entry.key.normalizedInstanceTag,
                            previousActive.instanceTag
                        ))
                }
            }
            return false
        }
        let restored = connectionState == .connected
            && remoteClient != nil
            && foregroundMacDeviceID.map { previousIDs.contains($0) } == true
        guard restored else { return restored }
        guard await isScopeCurrent(restoreScope), isRestoreCurrent() else { return restored }
        if let task = enqueueActivePairedMacWrite(
            macDeviceID: previousActive.macDeviceID,
            instanceTag: previousActive.instanceTag,
            scope: restoreScope,
            reloadAfterWrite: true
        ) {
            await task.value
        }
        return restored
    }

    func clearSavedMacHintWhenNoStoredMacsRemainIfNeeded() {
        guard pairedMacs.isEmpty, !hasHiddenComputers else { return }
        storedMacReconnectGeneration &+= 1
        hasKnownPairedMac = false
        isReconnectingStoredMac = false
        pendingForcedStoredMacReconnect = false
        didFinishStoredMacReconnectAttempt = false
    }

    /// Enqueues one paired-Mac store mutation on the serialized write chain.
    ///
    /// All `markActive` writes go through here so they execute strictly in
    /// submission order, and `ifStillCurrent` is re-evaluated at EXECUTION
    /// time (after every earlier write has fully landed), not at submission.
    /// That closes the check-then-await race: a stale status-adoption task
    /// either observes it lost currency and skips, or it is still current
    /// and any newer connection's write is queued strictly behind it and
    /// overwrites the active mark. The chain is deliberately not cancelled
    /// on disconnect; in-flight writes complete or skip via their own check.
    @discardableResult
    private func enqueueSerializedPairedMacWrite(
        ifStillCurrent: (() -> Bool)?,
        _ operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let previous = pairedMacWriteChain
        let task = Task { @MainActor in
            await previous?.value
            if let ifStillCurrent, !ifStillCurrent() { return }
            await operation()
        }
        pairedMacWriteChain = task
        return task
    }

    /// Runs one paired-Mac store mutation on the serialized write chain.
    func performSerializedPairedMacWrite(
        ifStillCurrent: (() -> Bool)?,
        _ operation: @escaping @MainActor () async -> Void
    ) async {
        let task = enqueueSerializedPairedMacWrite(
            ifStillCurrent: ifStillCurrent,
            operation
        )
        await task.value
    }

    @discardableResult
    func enqueueActivePairedMacWrite(
        macDeviceID: String,
        instanceTag: String? = nil,
        scope: MobileShellScopeSnapshot?,
        reloadAfterWrite: Bool
    ) -> Task<Void, Never>? {
        guard let pairedMacStore else { return nil }
        return enqueueSerializedPairedMacWrite(ifStillCurrent: nil) { [weak self, pairedMacStore] in
            guard let self else { return }
            if let scope {
                guard await self.isScopeCurrent(scope) else { return }
            }
            guard self.connectionState == .connected,
                  self.remoteClient != nil,
                  (self.foregroundMacDeviceID.map {
                      MacPairingKey(
                          macDeviceID: $0,
                          instanceTag: self.activeMacInstanceTag
                      ) == MacPairingKey(
                          macDeviceID: macDeviceID,
                          instanceTag: instanceTag
                      )
                  } == true) else { return }
            do {
                try await pairedMacStore.setActive(
                    macDeviceID: macDeviceID,
                    instanceTag: instanceTag,
                    stackUserID: scope?.userID,
                    teamID: scope?.teamID
                )
                guard self.connectionState == .connected,
                      self.remoteClient != nil,
                      (self.foregroundMacDeviceID.map {
                          MacPairingKey(
                              macDeviceID: $0,
                              instanceTag: self.activeMacInstanceTag
                          ) == MacPairingKey(
                              macDeviceID: macDeviceID,
                              instanceTag: instanceTag
                          )
                      } == true) else { return }
                if reloadAfterWrite {
                    await self.loadPairedMacs()
                }
            } catch {
                mobileShellLog.error("paired mac store setActive failed mac=\(macDeviceID, privacy: .private) error=\(String(describing: error), privacy: .public)")
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
        guard activeTicket?.macDeviceID.isEmpty == true || activeMacInstanceTag == nil else { return }
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
            // This runs with the full RPC timeout when the 750ms transport probe
            // timed out, so it is also the recovery path for theme adoption: the
            // probe applies the theme when it succeeds, but on a slow link it
            // fails fast and never does. applyTerminalTheme is idempotent (it
            // only bumps the generation on a real change), so re-applying here is
            // free in the common case and keeps the phone's colors in sync with
            // the Mac even when the probe could not.
            self.applyTerminalTheme(payload.theme)
            self.refreshMacUpdateHintFromRecoveredStatus(payload)
            await self.applyHostReportedIdentity(
                client: client,
                deviceID: payload.macDeviceID,
                displayName: payload.macDisplayName,
                instanceTag: payload.macInstanceTag,
                clientNamespace: payload.macClientNamespace,
                macAppVersion: payload.macAppVersion
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
    func applyHostReportedIdentity(
        client: MobileCoreRPCClient,
        deviceID: String?,
        displayName: String?,
        instanceTag: String?,
        clientNamespace: String? = nil,
        macAppVersion: String? = nil
    ) async {
        guard remoteClient === client,
              let rawReportedID = deviceID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawReportedID.isEmpty,
              let ticket = activeTicket else { return }
        let reportedID = cmxCanonicalDeviceID(rawReportedID)
        let resolvedTicket: CmxAttachTicket
        if ticket.macDeviceID.isEmpty,
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
            resolvedTicket = adopted
        } else {
            // An authenticated status response may refresh metadata only for
            // the Mac this connection already represents. A mismatched reply
            // cannot rewrite another paired record.
            guard macInstanceTagAuthority.authenticatedDeviceMatches(
                reportedDeviceID: reportedID,
                expectedDeviceID: ticket.macDeviceID
            ) else {
                rejectForegroundHostIdentity(client: client, reason: "device_id_mismatch")
                return
            }
            resolvedTicket = ticket
        }
        guard remoteClient === client else { return }
        let resolvedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTag = instanceTag?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard authenticatedMacBuildIsCompatible(
            instanceTag: resolvedTag,
            clientNamespace: clientNamespace,
            macAppVersion: macAppVersion,
            client: client
        ) else {
            rejectForegroundHostIdentity(client: client, reason: "build_incompatible")
            return
        }
        if let activeMacInstanceTag,
           let resolvedTag,
           !resolvedTag.isEmpty,
           activeMacInstanceTag != resolvedTag {
            rejectForegroundHostIdentity(client: client, reason: "instance_tag_mismatch")
            return
        }
        let tagUpdate: PairedMacInstanceTagUpdate
        if resolvedTag?.isEmpty == false {
            tagUpdate = .replace(resolvedTag)
        } else if activeMacInstanceTag == nil {
            tagUpdate = .preserveOnlyIfUnclaimed
        } else {
            tagUpdate = .preserve
        }
        let accepted = await persistPairedMacFromTicket(
            resolvedTicket,
            instanceTagUpdate: tagUpdate,
            displayNameOverride: resolvedName?.isEmpty == false ? resolvedName : nil,
            ifStillCurrent: { [weak self] in self?.remoteClient === client }
        )
        guard remoteClient === client else { return }
        if !accepted {
            rejectForegroundHostIdentity(client: client, reason: "stored_instance_authority")
            return
        }
        // Publish the authenticated identity only after the paired store has
        // accepted its instance authority. An anonymous no-tag status must not
        // displace an already-authenticated warm control owner for this Mac.
        if ticket.macDeviceID.isEmpty {
            activeTicket = resolvedTicket
        }
        if let resolvedName, !resolvedName.isEmpty {
            connectedHostName = resolvedName
        }
        let foregroundKeyBeforeTagAdoption = foregroundMacKey
        if activeMacInstanceTag == nil, let resolvedTag, !resolvedTag.isEmpty {
            activeMacInstanceTag = resolvedTag
        }
        adoptForegroundMacIdentity(
            reportedID,
            previousKey: foregroundKeyBeforeTagAdoption
        )
    }

    private func rejectForegroundHostIdentity(
        client: MobileCoreRPCClient,
        reason: String
    ) {
        guard remoteClient === client else { return }
        mobileShellLog.error("disconnecting mismatched authenticated Mac identity reason=\(reason, privacy: .public)")
        connectionState = .disconnected
        macConnectionStatus = .unavailable
        clearRemoteConnectionContext(
            preservingOtherMacWorkspaceState: true
        )
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

    /// - Parameter userEnteredPairingCode: `true` only when the value came from
    ///   an explicit in-app pairing-code entry (camera scan or paste in the
    ///   pairing UI). That physical act of reading the code off the Mac is what
    ///   authorizes dialing a compatibility Tailscale destination; a URL opened
    ///   from another app never gets that power.
    @discardableResult
    public func connectPairingURLResult(
        _ rawValue: String? = nil,
        userEnteredPairingCode: Bool = false
    ) async -> MobilePairingURLConnectionResult {
        await connectPairingURLResult(
            rawValue,
            acceptedVersionWarning: false,
            userEnteredPairingCode: userEnteredPairingCode
        )
    }

    @discardableResult
    private func connectPairingURLResult(
        _ rawValue: String? = nil,
        acceptedVersionWarning: Bool,
        userEnteredPairingCode: Bool = false
    ) async -> MobilePairingURLConnectionResult {
        MobileDebugLog.shared.append(
            "pairing.qr_connect.begin user_entered=\(userEnteredPairingCode) accepted_version_warning=\(acceptedVersionWarning)"
        )
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
            MobileDebugLog.shared.append(
                "pairing.qr_decode.success route_count=\(ticket.routes.count) route_kinds=\(ticket.routes.map(\.kind.rawValue).sorted().joined(separator: ","))"
            )
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
            MobileDebugLog.shared.append(
                // Type-only: a decode error can embed the scanned payload.
                "pairing.qr_decode.failed error_type=\(type(of: error))"
            )
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

        let accountPreflight = MobilePairingAccountPreflight(
            scannedScheme: URLComponents(string: rawURL)?.scheme,
            actualUserID: identityProvider?.currentUserID,
            actualEmail: identityProvider?.currentUserEmail,
            isDevelopmentAuthEnvironment: identityProvider?.isDevelopmentAuthEnvironment ?? false
        )
        if let emailFailure = accountPreflight.failure(for: ticket) {
            MobileDebugLog.shared.append(
                "pairing.account_preflight.failed category=\(emailFailure)"
            )
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
            pendingPairingVersionWarningWasUserEntered = userEnteredPairingCode
            pairingVersionWarning = warning
            return .needsUserApproval
        }

        // An explicit in-app code entry (the Mac's Tailscale pairing window
        // shows either the tokenless v1 compatibility ticket or the bare-route
        // v2 grammar) authorizes the exact Tailscale destinations it named.
        // External URL opens never mint this.
        let userTailscalePairingAuthorizations: [CmxUserTailscalePairingAuthorization]
        if userEnteredPairingCode {
            userTailscalePairingAuthorizations = ticket.routes.compactMap { route in
                guard route.kind == .tailscale,
                      case let .hostPort(host, port) = route.endpoint else {
                    return nil
                }
                return try? CmxUserTailscalePairingAuthorization(host: host, port: port)
            }
        } else {
            userTailscalePairingAuthorizations = []
        }

        let attemptID = beginPairingAttempt(method: "qr")

        // Offline preflight: fail fast instead of stacking per-route connect
        // timeouts into the opaque ~60s wait. Skipped only when no route is
        // dialable so `connect()` classifies that as `no_supported_route`.
        // Ticket expiry deliberately does NOT gate this: a stale QR is a valid
        // pairing input now (expiry is enforced solely where the RPC attach
        // token is used), so an expired legacy code scanned offline must say
        // "offline", not crawl the route loop's stacked timeouts.
        let candidateRoutes = supportedRoutes(
            for: ticket,
            supportedKinds: runtime?.supportedRouteKinds ?? [],
            userTailscalePairingAuthorizations: userTailscalePairingAuthorizations
        )
        MobileDebugLog.shared.append(
            "pairing.attempt.started route_count=\(candidateRoutes.count) supported_route_kinds=\(candidateRoutes.map(\.kind.rawValue).sorted().joined(separator: ","))"
        )
        if !candidateRoutes.isEmpty {
            switch await failPairingIfOffline(attemptID: attemptID, phase: "preflight", routes: candidateRoutes) {
            case .failedOffline: return .failed
            case .superseded: return .superseded
            case .proceed: break
            }
        }

        do {
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            let noThrowFailure = try await connect(
                ticket: ticket,
                userTailscalePairingAuthorizations: userTailscalePairingAuthorizations
            )
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            if connectionState == .connected && activeTicket != nil {
                // Fresh pairing persists the Mac during `connect(ticket:)`, but
                // presentation surfaces read the shared in-memory list. Refresh
                // it before reporting success so an immediately opened picker or
                // task composer sees the Mac without a manual Computers refresh.
                await loadPairedMacs()
                guard isCurrentPairingAttempt(attemptID) else { return .superseded }
                recordPairingSucceeded()
                MobileDebugLog.shared.append("pairing.attempt.succeeded")
                return .connected
            }
            // `connect()` returned without connecting and already set a
            // specific error; record without overwriting that message.
            recordFailureForCurrentConnectionError(phase: "connect", category: noThrowFailure)
            MobileDebugLog.shared.append(
                "pairing.attempt.failed_without_throw category=\(noThrowFailure.map(String.init(describing:)) ?? "nil")"
            )
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
            MobileDebugLog.shared.append(
                "pairing.attempt.failed error=\(String(describing: error))"
            )
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
        if let startedAt = pairingAttemptStartedAt, pairingAttemptMethod != nil {
            recordAppEvent(
                .pairingCancelled,
                startedAt: startedAt,
                failure: .cancelled
            )
        }
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

    /// Supersede the in-flight paired-Mac switch without applying the broader
    /// pairing-cancel UI teardown. Used by picker surfaces that abandon a switch
    /// request before it reaches the foreground mutation point.
    @discardableResult
    public func cancelPendingMacSwitch(restorePreviousOnCancel: Bool = false) -> Task<Bool, Never>? {
        guard let attemptID = macSwitchAttemptID else { return nil }
        let restoreTarget = restorePreviousOnCancel ? macSwitchRestoreBaseline : nil
        let restoreSignInGeneration = signInGeneration
        let restoreScopeGeneration = secondaryAggregationScopeGeneration
        macSwitchCancelRestoreGeneration &+= 1
        let restoreGeneration = macSwitchCancelRestoreGeneration
        if restorePreviousOnCancel, restoreTarget == nil {
            macSwitchRestorePreviousOnCancelAttemptIDs.insert(attemptID)
        }
        macSwitchAttemptID = nil
        macSwitchAttemptSignInGeneration = nil
        invalidatePairingAttempt()
        connectionAttemptGeneration = UUID()
        if let restoreTarget {
            return Task { @MainActor [weak self] in
                guard let self else { return false }
                guard self.isSignedIn,
                      self.signInGeneration == restoreSignInGeneration,
                      self.secondaryAggregationScopeGeneration == restoreScopeGeneration,
                      self.macSwitchAttemptID == nil,
                      self.macSwitchCancelRestoreGeneration == restoreGeneration else { return false }
                let restored = await self.restorePreviousMacIfNeeded(
                    restoreTarget,
                    cancelRestoreGeneration: restoreGeneration
                )
                if self.macSwitchAttemptID == nil,
                   self.signInGeneration == restoreSignInGeneration,
                   self.secondaryAggregationScopeGeneration == restoreScopeGeneration,
                   self.macSwitchCancelRestoreGeneration == restoreGeneration {
                    self.macSwitchRestoreBaseline = nil
                }
                return restored
            }
        }
        return nil
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
        let wasUserEntered = pendingPairingVersionWarningWasUserEntered
        clearPairingVersionWarning()
        return await connectPairingURLResult(
            rawURL,
            acceptedVersionWarning: true,
            userEnteredPairingCode: wasUserEntered
        )
    }

    /// Tear down the live connection and reset connection UI state, without
    /// touching the paired-Mac store or the restoring-gate hint. The switcher's
    /// ``hideMac(macDeviceID:)`` and ``switchToMac(macDeviceID:)`` reuse this,
    /// so it must not clear ``hasKnownPairedMac``; hiding changes list visibility,
    /// not whether a stored paired Mac is known.
    func disconnectLiveConnection(preservingOtherMacWorkspaceState: Bool = false) {
        suppressNextConnectionOutageEdge = true
        invalidatePairingAttempt()
        clearMacSwitchAttemptState()
        clearPairingError()
        connectionRequiresReauth = false
        connectionState = .disconnected
        macConnectionStatus = .unavailable
        clearRemoteConnectionContext(preservingOtherMacWorkspaceState: preservingOtherMacWorkspaceState)
    }

    /// Disconnect from and hide the currently paired Mac on this device without
    /// deleting local or server pairing state.
    /// Backs the "Forget This Computer" action.
    public func disconnectAndHideActiveMac() {
        let staleMacID = connectedMacDeviceID ?? activeTicket?.macDeviceID
        let staleMacInstanceTag = connectedMacInstanceTag
        let staleRepresentativeID = staleMacID.map {
            MobilePairedMac.pairingID(
                macDeviceID: $0,
                instanceTag: staleMacInstanceTag
            )
        }
        let staleAliasIDs = staleMacID.map {
            pairedMacAliasIDs(for: $0, instanceTag: staleMacInstanceTag)
        } ?? []
        disconnectLiveConnection()
        // Bump the reconnect generation so an in-flight reconnect cannot reclaim
        // the foreground while the retained pairing is being hidden. Preserve the
        // known-Mac hint: hiding changes list visibility, not the app's shell mode.
        storedMacReconnectGeneration &+= 1
        isReconnectingStoredMac = false
        pendingForcedStoredMacReconnect = false
        didFinishStoredMacReconnectAttempt = false
        if let representativeID = staleRepresentativeID {
            hasKnownPairedMac = true
            // The shell action is synchronous for its UI caller; the device-local
            // marker and list pruning continue on the main actor without deleting
            // the retained paired-Mac row.
            Task {
                await self.hideStoredPairedMacEntries(
                    representativeID: representativeID,
                    aliasIDs: staleAliasIDs
                )
            }
        }
    }

    /// Build a persistent read-only client to one OTHER Mac. The typed outcome
    /// separates network failures, which share the pool retry budget, from
    /// authority/build/route incompatibilities, which wait for a new external
    /// edge instead of polling forever.
    ///
    /// Route selection honors the user's connection method exactly like the
    /// foreground dial: with Tailscale selected, a Mac without a device-local
    /// Tailscale grant fails closed here instead of opening a background Iroh
    /// control session over public paths and managed relays.
    func makeSecondaryClient(
        for mac: MobilePairedMac
    ) async -> SecondaryClientAttempt {
        guard let runtime else { return .permanentFailure }
        let supportedKinds = runtime.supportedRouteKinds
        // Background control obeys the per-Computer method allowlist exactly
        // like the foreground dial: pinned addresses only, fail closed.
        let directOnlyCandidates = irohMethodPinnedDialCandidates(
            forMacDeviceID: mac.macDeviceID,
            instanceTag: mac.instanceTag,
            knownPairing: mac
        )
        if let directOnlyCandidates, directOnlyCandidates.isEmpty {
            return .permanentFailure
        }
        let pinnedRoutes = orderedReconnectRoutes(
            for: mac,
            supportedKinds: supportedKinds
        )
        guard let firstRoute = pinnedRoutes.first else {
            return .permanentFailure
        }
        let ticket: CmxAttachTicket
        let route: CmxAttachRoute
        let legacyTailscaleAuthorizationEvidence: CmxLegacyTailscaleAuthorizationEvidence?
        if firstRoute.kind == .iroh {
            do {
                ticket = try Self.storedMacTicket(
                    name: mac.displayName ?? mac.macDeviceID,
                    routes: pinnedRoutes,
                    pairedMacDeviceID: mac.macDeviceID
                )
                route = firstRoute
                legacyTailscaleAuthorizationEvidence = nil
            } catch {
                mobileShellLog.warning(
                    "secondary client: invalid stored ticket mac=\(mac.macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                return .permanentFailure
            }
        } else if let authorizedLegacyRoute = pinnedRoutes.first(where: { candidate in
            Self.legacyTailscaleAuthorizationEvidence(
                for: candidate,
                macDeviceID: mac.macDeviceID,
                persistedRoutes: mac.legacyTailscaleRoutes ?? []
            ) != nil
        }) {
            do {
                ticket = try Self.storedMacTicket(
                    name: mac.displayName ?? mac.macDeviceID,
                    routes: [authorizedLegacyRoute],
                    pairedMacDeviceID: mac.macDeviceID
                )
                route = authorizedLegacyRoute
                legacyTailscaleAuthorizationEvidence = Self
                    .legacyTailscaleAuthorizationEvidence(
                        for: authorizedLegacyRoute,
                        macDeviceID: mac.macDeviceID,
                        persistedRoutes: mac.legacyTailscaleRoutes ?? []
                    )
            } catch {
                mobileShellLog.warning(
                    "secondary client: invalid legacy ticket mac=\(mac.macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                return .permanentFailure
            }
        } else if firstRoute.kind == .tailscale {
            // Restored Tailscale rows intentionally omit the device-local
            // authorization grant. Background aggregation must not turn them
            // into a periodic manual-ticket exchange.
            return .permanentFailure
        } else {
            guard let (host, port) = Self.firstReconnectHostPortRoute(
                pinnedRoutes,
                supportedKinds: supportedKinds,
                preferNonLoopback: Self.prefersNonLoopbackRoutes
            ) else {
                return .permanentFailure
            }
            do {
                ticket = try await manualHostTicket(
                    name: mac.displayName ?? host,
                    host: host,
                    port: port,
                    attemptStartedAt: nil
                )
            } catch {
                mobileShellLog.warning(
                    "secondary client: ticket exchange failed mac=\(mac.macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                return secondaryControlAttemptIsTransient(error)
                    ? .transientFailure
                    : .permanentFailure
            }
            let supportedRoutes = supportedRoutes(
                for: ticket,
                supportedKinds: supportedKinds,
                pairedMacDeviceID: mac.macDeviceID,
                instanceTag: mac.instanceTag
            )
            guard let selectedRoute = supportedRoutes.first(where: { candidate in
                if case let .hostPort(routeHost, routePort) = candidate.endpoint {
                    return routeHost == host && routePort == port
                }
                return false
            }) ?? supportedRoutes.first(where: { $0.kind != .debugLoopback })
                ?? supportedRoutes.first else {
                return .permanentFailure
            }
            route = selectedRoute
            legacyTailscaleAuthorizationEvidence = nil
        }
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: MobileShellRouteAuthPolicy.routeAllowsStackAuth(route),
            legacyTailscaleAuthorizationEvidence: legacyTailscaleAuthorizationEvidence,
            irohDirectOnlyDialCandidates: directOnlyCandidates,
            connectAttemptRegistry: connectAttemptRegistry,
            stackTokenGate: stackTokenGate,
            stackTokenForceRefreshGate: stackTokenForceRefreshGate,
            transportConnectObserver: transportConnectDiagnosticObserver(
                peerID: mac.macDeviceID
            ),
            sessionPurpose: .backgroundControl
        )
        var status: MobileHostStatusResponse
        switch await fetchSecondaryHostStatus(on: client) {
        case let .received(receivedStatus):
            status = receivedStatus
        case .transientFailure:
            await disconnectSecondaryClientAndDrain(client)
            return .transientFailure
        case .permanentFailure:
            await disconnectSecondaryClientAndDrain(client)
            return .permanentFailure
        }
        if macInstanceTagAuthority.secondaryStatusAuthority(
            expectedDeviceID: mac.macDeviceID,
            storedInstanceTag: mac.instanceTag,
            reportedDeviceID: status.macDeviceID,
            reportedInstanceTag: status.macInstanceTag
        ) == .identityUnavailable,
           (MobileShellRouteAuthPolicy.routeAllowsStackAuth(route)
               || legacyTailscaleAuthorizationEvidence != nil) {
            // Status intentionally uses only a cached token. If it cannot prove
            // identity, perform one authorized request that may refresh Stack
            // credentials, then bind the status response to that exact token.
            switch await fetchSecondaryAuthenticatedHostStatus(on: client) {
            case let .received(receivedStatus):
                status = receivedStatus
            case .transientFailure:
                await disconnectSecondaryClientAndDrain(client)
                return .transientFailure
            case .permanentFailure:
                await disconnectSecondaryClientAndDrain(client)
                return .permanentFailure
            }
        }
        switch macInstanceTagAuthority.secondaryStatusAuthority(
            expectedDeviceID: mac.macDeviceID,
            storedInstanceTag: mac.instanceTag,
            reportedDeviceID: status.macDeviceID,
            reportedInstanceTag: status.macInstanceTag
        ) {
        case .accepted:
            break
        case .identityUnavailable:
            await disconnectSecondaryClientAndDrain(client)
            return .permanentFailure
        case .rejected:
            mobileShellLog.warning(
                "secondary client rejected mismatched authenticated identity mac=\(mac.macDeviceID, privacy: .private)"
            )
            await disconnectSecondaryClientAndDrain(client)
            return .permanentFailure
        }
        let capabilities = Set(status.capabilities)
        if !capabilities.contains("events.v1") {
            mobileShellLog.info(
                "secondary client using refresh-only fallback mac=\(mac.macDeviceID, privacy: .private)"
            )
        }
        return .connected(SecondaryClientHandle(
            client: client,
            route: route,
            ticket: ticket,
            storedInstanceTag: macInstanceTagAuthority.normalize(mac.instanceTag),
            authenticatedInstanceTag: macInstanceTagAuthority.normalize(
                status.macInstanceTag
            ),
            supportedHostCapabilities: capabilities,
            actionCapabilities: Self.workspaceActionCapabilities(
                from: capabilities,
                allowsMacScopedMutations: MobileShellWorkspaceMutationTicketPolicy(now: runtime.now())
                    .allowsMacScopedWorkspaceMutations(
                        ticket,
                        hostAuthorizesByAccount: capabilities.contains(Self.workspaceMutationAccountAuthCapability)
                    )
            )
        ))
    }

    /// A candidate secondary client owns a physical route before it is
    /// published to the registry. Wait for its transport admission and close
    /// work before allowing a replacement flight to reuse that route.
    private func disconnectSecondaryClientAndDrain(
        _ client: MobileCoreRPCClient
    ) async {
        await client.disconnectAndWaitForTransportDrain()
    }

    private func fetchSecondaryHostStatus(
        on client: MobileCoreRPCClient
    ) async -> SecondaryHostStatusAttempt {
        guard let runtime else { return .permanentFailure }
        do {
            let data = try await client.sendRequest(
                MobileCoreRPCClient.requestData(method: "mobile.host.status", params: [:]),
                timeoutNanoseconds: runtime.pairingRequestTimeoutNanoseconds
            )
            guard let response = try? MobileHostStatusResponse.decode(data) else {
                mobileShellLog.warning(
                    "secondary host status returned an incompatible response"
                )
                return .permanentFailure
            }
            return .received(response)
        } catch {
            mobileShellLog.warning("secondary host status failed: \(String(describing: error), privacy: .private)")
            return secondaryControlAttemptIsTransient(error)
                ? .transientFailure
                : .permanentFailure
        }
    }

    private func fetchSecondaryAuthenticatedHostStatus(
        on client: MobileCoreRPCClient
    ) async -> SecondaryHostStatusAttempt {
        guard let runtime else { return .permanentFailure }
        do {
            let exchange = try await client.sendRequestAndAuthenticatedHostStatus(
                MobileCoreRPCClient.requestData(
                    method: "workspace.list",
                    params: [:]
                ),
                timeoutNanoseconds: runtime.pairingRequestTimeoutNanoseconds,
                hostStatusTimeoutNanoseconds: {
                    runtime.pairingRequestTimeoutNanoseconds
                }
            )
            guard let response = try? MobileHostStatusResponse.decode(
                exchange.hostStatusResponse
            ) else {
                return .permanentFailure
            }
            return .received(response)
        } catch {
            mobileShellLog.warning(
                "secondary authenticated host status failed: \(String(describing: error), privacy: .private)"
            )
            return secondaryControlAttemptIsTransient(error)
                ? .transientFailure
                : .permanentFailure
        }
    }

    /// Fetch one Mac's workspace list over an EXISTING client, tagged with its
    /// `macDeviceID`. Transport failures remain retryable, while incompatible
    /// responses and permanent RPC rejections wait for new authority evidence.
    func fetchSecondaryWorkspaces(
        on client: MobileCoreRPCClient,
        macDeviceID: String
    ) async -> SecondaryWorkspaceFetchAttempt {
        guard let runtime else { return .permanentFailure }
        guard let requestData = try? MobileCoreRPCClient.requestData(
            method: "workspace.list",
            params: [:]
        ) else {
            return .permanentFailure
        }
        let resultData: Data
        do {
            resultData = try await client.sendRequest(
                requestData,
                timeoutNanoseconds: runtime.pairingRequestTimeoutNanoseconds
            )
        } catch {
            mobileShellLog.warning(
                "secondary workspace fetch failed mac=\(macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return secondaryControlAttemptIsTransient(error)
                ? .transientFailure
                : .permanentFailure
        }
        guard let response = try? MobileSyncWorkspaceListResponse.decode(
            resultData
        ) else {
            mobileShellLog.warning(
                "secondary workspace fetch returned an incompatible response mac=\(macDeviceID, privacy: .public)"
            )
            return .permanentFailure
        }
        let workspaces = response.workspaces.map { remote in
            var workspace = MobileWorkspacePreview(remote: remote)
            workspace.macDeviceID = macDeviceID
            return workspace
        }
        let groups = Self.remoteWorkspaceGroups(
            from: response,
            acceptsEmptyGroupSnapshot: !response.workspaces.contains { workspace in
                workspace.groupID?.isEmpty == false
            }
        )
        return .received(SecondaryWorkspaceSnapshot(
            workspaces: workspaces,
            groups: groups
        ))
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
        guard foregroundRefreshIsActive, !Task.isCancelled else { return false }
        return await isScopeCurrent(scope)
    }

    /// Launch the multi-Mac aggregation in a tracked task so sign-out / account
    /// switch can cancel it (its scope guards then bail before any cross-account
    /// write). Presence can publish several rows for one heartbeat; coalesce those
    /// triggers into one in-flight pass plus one trailing pass so a valid connect
    /// is never starved by cancel/restart churn.
    func scheduleSecondaryAggregation(discoverLivePeers: Bool = false) {
        if discoverLivePeers {
            secondaryIrohDiscoveryPending = true
        }
        guard foregroundRefreshIsActive else { return }
        guard secondaryAggregationTask == nil else {
            secondaryAggregationPending = true
            return
        }
        let taskGeneration = UUID()
        secondaryAggregationTaskGeneration = taskGeneration
        secondaryAggregationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.secondaryAggregationPending = false
                let discoverLivePeers = self.secondaryIrohDiscoveryPending
                self.secondaryIrohDiscoveryPending = false
                await self.refreshSecondaryMacWorkspaces(
                    allowsNewConnections: self.secondaryAggregationRetryTask == nil,
                    discoverLivePeers: discoverLivePeers
                )
            } while self.secondaryAggregationTaskGeneration == taskGeneration
                && self.secondaryAggregationPending
                && !Task.isCancelled
            guard self.secondaryAggregationTaskGeneration == taskGeneration else { return }
            self.secondaryAggregationTask = nil
            self.secondaryAggregationPending = false
        }
    }

    /// Preserve a broker-discovery request when a transient candidate failure
    /// occurs before that candidate can be persisted as a paired row.
    func preserveSecondaryIrohDiscoveryIntent() {
        secondaryIrohDiscoveryPending = true
    }

    func scheduleSecondaryPresenceAggregation(
        forMacDeviceID macDeviceID: String
    ) {
        secondaryPresencePendingMacIDs.insert(cmxCanonicalDeviceID(macDeviceID))
        guard foregroundRefreshIsActive else { return }
        guard secondaryPresenceAggregationTask == nil else { return }
        let taskGeneration = UUID()
        secondaryPresenceAggregationTaskGeneration = taskGeneration
        secondaryPresenceAggregationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.secondaryPresencePendingMacIDs.isEmpty,
                  !Task.isCancelled {
                let macIDs = self.secondaryPresencePendingMacIDs
                self.secondaryPresencePendingMacIDs = []
                await self.refreshSecondaryMacWorkspaces(
                    onlyMacDeviceIDs: macIDs,
                    allowsNewConnections: self.secondaryAggregationRetryTask == nil
                )
            }
            guard self.secondaryPresenceAggregationTaskGeneration
                    == taskGeneration else {
                return
            }
            self.secondaryPresenceAggregationTask = nil
        }
    }

    func refreshSecondaryMacWorkspaces(
        onlyMacDeviceIDs: Set<String>? = nil,
        allowsNewConnections: Bool = true,
        discoverLivePeers: Bool = false
    ) async {
        guard let pairedMacStore else { return }
        if !multiMacAggregationEnabled {
            // The aggregation preference controls ongoing workspace fan-out,
            // not account admission. A legacy install may have this switch
            // persisted as false, but opening the app must still discover and
            // persist every authenticated Mac instance so Computer Order is
            // complete without a QR per build.
            guard discoverLivePeers,
                  connectionState == .connected,
                  remoteClient != nil,
                  let scope = await currentScopeSnapshot(),
                  await isAggregationScopeValid(scope) else { return }
            let loadedMacs = (try? await pairedMacStore.loadAll(
                stackUserID: scope.userID,
                teamID: scope.teamID
            )) ?? []
            guard await isAggregationScopeValid(scope) else { return }
            await establishDiscoveredSecondaryIrohMacs(
                scope: scope,
                excluding: loadedMacs
            )
            return
        }
        let retryEvidenceGenerationAtStart =
            secondaryAggregationRetryEvidenceGeneration
        // Require a concrete signed-in user before any load/connection: a nil/empty
        // account would make `loadAll(stackUserID: nil)` read EVERY locally stored
        // Mac across Stack accounts and publish another account's workspaces into
        // this UI (the scope guard alone passes for nil == nil). Mirrors
        // loadPairedMacs()'s account requirement.
        guard let scope = await currentScopeSnapshot() else {
            // A transient exit must not consume the one-shot discovery intent:
            // the retry re-enters through scheduleSecondaryAggregation, which
            // only rediscovers when the pending flag survived.
            if discoverLivePeers { secondaryIrohDiscoveryPending = true }
            return
        }
        // Full snapshots and explicit refreshes reconcile the account backup.
        // Targeted presence updates already persisted their pushed route and must
        // not turn one Mac's churn into an account-wide network fetch.
        if onlyMacDeviceIDs == nil,
           let refresher = pairedMacStore as? any PairedMacBackupRefreshing {
            await refresher.refreshFromBackup(stackUserID: scope.userID)
        }
        guard await isAggregationScopeValid(scope) else { return }
        let rawRequestedCanonicalIDs = onlyMacDeviceIDs.map {
            Set($0.map(cmxCanonicalDeviceID))
        }
        let requestedCanonicalIDs: Set<String>?
        if let rawRequestedCanonicalIDs {
            guard let expanded = expandedStoredAliasCanonicalIDs(
                rawRequestedCanonicalIDs,
                scope: scope
            ) else {
                // Startup and scope transitions have no trusted index yet. One
                // coalesced full pass establishes it for following edges.
                scheduleSecondaryAggregation()
                return
            }
            requestedCanonicalIDs = expanded
        } else {
            requestedCanonicalIDs = nil
        }
        let loadedMacs: [MobilePairedMac]
        let authorityValidation: SecondaryStoredAuthorityValidation
        if let requestedCanonicalIDs {
            guard let targetedMacs = targetedStoredPairedMacs(
                requestedCanonicalIDs: requestedCanonicalIDs,
                scope: scope
            ) else {
                // Startup and scope transitions have no trusted index yet. One
                // coalesced full pass establishes it for following edges.
                scheduleSecondaryAggregation()
                return
            }
            loadedMacs = targetedMacs
            authorityValidation = .cached
        } else {
            do {
                loadedMacs = try await pairedMacStore.loadAll(
                    stackUserID: scope.userID,
                    teamID: scope.teamID
                )
            } catch {
                guard await isAggregationScopeValid(scope) else { return }
                pairedMacLoadState = .failed
                var retryMacIDs = Set(
                    storedPairedMacsIncludingHidden.map(\.macDeviceID)
                )
                retryMacIDs.formUnion(
                    secondaryMacSubscriptions.keys.map(\.canonicalMacDeviceID)
                )
                retryMacIDs.formUnion(
                    workspacesByMac.keys.compactMap {
                        $0 == .anonymousForeground ? nil : $0.canonicalMacDeviceID
                    }
                )
                retryMacIDs.formUnion(
                    notificationFeedSnapshotsByMac.keys.map {
                        MacPairingKey(pairingID: $0).canonicalMacDeviceID
                    }
                )
                scheduleSecondaryAggregationRetry(
                    macDeviceIDs: retryMacIDs,
                    needsFullRefresh: true
                )
                mobileShellLog.error(
                    """
                    secondary paired mac store load failed: \
                    \(String(describing: error), privacy: .public)
                    """
                )
                // A failed store load must not consume the one-shot discovery
                // intent: the scheduled full-refresh retry re-enters through
                // scheduleSecondaryAggregation, which only rediscovers when
                // the pending flag survived.
                if discoverLivePeers { secondaryIrohDiscoveryPending = true }
                return
            }
            authorityValidation = .store
        }
        guard await isAggregationScopeValid(scope) else { return }
        if onlyMacDeviceIDs == nil {
            pairedMacLoadState = .loaded
        }
        let visibleLoadedMacs = await visibleStoredPairedMacs(from: loadedMacs, scope: scope)
        guard await isAggregationScopeValid(scope) else { return }
        if onlyMacDeviceIDs == nil {
            installStoredPairedMacCache(loadedMacs, scope: scope)
        }
        func isRequested(_ macDeviceID: String) -> Bool {
            requestedCanonicalIDs?.contains(cmxCanonicalDeviceID(macDeviceID))
                ?? true
        }
        let macs = secondaryAggregationTargets(
            from: visibleLoadedMacs,
            requestedCanonicalIDs: requestedCanonicalIDs
        )
        var transientFailureMacIDs: Set<String> = []
        func recordEstablishmentOutcome(
            _ outcome: SecondaryMacEstablishmentOutcome,
            macDeviceID: String
        ) {
            if case .transientFailure = outcome {
                transientFailureMacIDs.insert(cmxCanonicalDeviceID(macDeviceID))
            }
        }
        let wanted = Set(macs.map(MacPairingKey.init))
        let wantedCanonicalIDs = Set(wanted.map(\.canonicalMacDeviceID))
        let visibleMacIDs = Set(visibleLoadedMacs.map(\.macDeviceID))
        let visibleCanonicalMacIDs = Set(
            visibleMacIDs.map(cmxCanonicalDeviceID)
        )
        let canonicalForegroundMacID = foregroundMacDeviceID.map(cmxCanonicalDeviceID)
        var retiredControlSlot = false
        if onlyMacDeviceIDs == nil {
            // A full store load is authoritative even when an offline Mac no
            // longer has a control subscription. Reconcile every retained
            // aggregate owner independently of transport ownership so a
            // removed or hidden pairing cannot leave stale UI state behind.
            var retainedOwnerKeys = Set(workspacesByMac.keys)
            for feedOwnerKey in notificationFeedSnapshotsByMac.keys {
                retainedOwnerKeys.insert(MacPairingKey(pairingID: feedOwnerKey))
            }
            for feedOwnerKey in notificationFeedKnownRevisionsByMac.keys {
                retainedOwnerKeys.insert(MacPairingKey(pairingID: feedOwnerKey))
            }
            for feedOwnerKey in notificationFeedSuccessfulMacIDs {
                retainedOwnerKeys.insert(MacPairingKey(pairingID: feedOwnerKey))
            }
            for feedOwnerKey in notificationFeedRefreshTasksByMac.keys {
                retainedOwnerKeys.insert(MacPairingKey(pairingID: feedOwnerKey))
            }
            for feedOwnerKey in notificationFeedRefreshRetryTasksByMac.keys {
                retainedOwnerKeys.insert(MacPairingKey(pairingID: feedOwnerKey))
            }
            for feedOwnerKey in notificationFeedRefreshPendingMacIDs {
                retainedOwnerKeys.insert(MacPairingKey(pairingID: feedOwnerKey))
            }
            let visibleOwnerKeys = Set(visibleLoadedMacs.map(MacPairingKey.init))
            let liveForegroundKey = foregroundMacKey
            for retainedOwnerKey in retainedOwnerKeys {
                guard retainedOwnerKey != .anonymousForeground,
                      retainedOwnerKey != liveForegroundKey,
                      // The foreground's device-keyed feed snapshot has no tag
                      // dimension; only the exact live foreground device keeps
                      // that spelling.
                      !(retainedOwnerKey.normalizedInstanceTag == nil
                        && retainedOwnerKey.canonicalMacDeviceID
                            == canonicalForegroundMacID),
                      !visibleOwnerKeys.contains(retainedOwnerKey) else {
                    continue
                }
                workspacesByMac[retainedOwnerKey] = nil
                removeNotificationFeedSnapshot(
                    macDeviceID: retainedOwnerKey.pairingID
                )
            }
        }
        // Tear down subscriptions for Macs that are gone or are now the foreground.
        // A focused client becomes a registry control owner before its transport
        // purpose update completes. It remains `remoteClient` until the target
        // focus publishes, so protect that provisional owner across the await.
        for (ownerKey, subscription) in secondaryMacSubscriptions
            where isRequested(ownerKey.canonicalMacDeviceID)
                && !wanted.contains(ownerKey)
                && subscription.client !== remoteClient
                && !subscription.isTransitioningToFocus {
            retiredControlSlot = true
            let canonicalMacID = ownerKey.canonicalMacDeviceID
            let physicalAliasCanonicalIDs =
                storedPairedMacAliasCanonicalIDsByCanonicalID[ownerKey.pairingID]
                    ?? [canonicalMacID]
            if !physicalAliasCanonicalIDs.isDisjoint(
                with: wantedCanonicalIDs
            ) {
                // The same physical Mac now has a different authoritative
                // stored pairing. Retire through the drain reservation so the
                // replacement's dial waits for this transport to close, and
                // drop this pairing's snapshots: its replacement publishes
                // fresh ones, so retaining these would duplicate stale rows
                // and route notification actions to a retired owner.
                await retireSecondaryControlOwner(
                    subscription,
                    shouldRetry: allowsNewConnections
                )
                workspacesByMac[ownerKey] = nil
                removeNotificationFeedSnapshot(macDeviceID: ownerKey.pairingID)
            } else if !visibleCanonicalMacIDs.contains(canonicalMacID) {
                subscription.cancel()
                secondaryMacSubscriptions[ownerKey] = nil
                // Pairing removal and hiding are authoritative deletion events.
                workspacesByMac[ownerKey] = nil
                removeNotificationFeedSnapshot(macDeviceID: ownerKey.pairingID)
            } else {
                subscription.cancel()
                secondaryMacSubscriptions[ownerKey] = nil
                if canonicalForegroundMacID != canonicalMacID {
                    // Presence only bounds live network ownership. Preserve the
                    // last snapshot from an offline Mac and make it visibly
                    // unavailable.
                    markSecondaryMacUnavailable(ownerKey)
                }
            }
        }
        // Reconcile the bounded warm pool concurrently. Keep the task-group
        // width explicit here as a second resource boundary if target
        // selection changes later.
        let reconciliationMacs = macs.filter {
            wanted.contains(MacPairingKey($0))
        }
        let reconciliationResults = await withTaskGroup(
            of: SecondaryMacReconciliationResult.self,
            returning: [SecondaryMacReconciliationResult].self
        ) { group in
            var pending = reconciliationMacs.makeIterator()
            var results: [SecondaryMacReconciliationResult] = []
            results.reserveCapacity(reconciliationMacs.count)

            for _ in 0 ..< Self.maximumSecondaryReconciliationConcurrency {
                guard let mac = pending.next() else { break }
                group.addTask { [weak self] in
                    guard let self else {
                        return SecondaryMacReconciliationResult(
                            macDeviceID: mac.macDeviceID,
                            establishmentOutcome: .superseded
                        )
                    }
                    return await self.reconcileSecondaryMac(
                        mac,
                        scope: scope,
                        authorityValidation: authorityValidation,
                        allowsNewConnections: allowsNewConnections
                    )
                }
            }
            while let result = await group.next() {
                results.append(result)
                guard let mac = pending.next() else { continue }
                group.addTask { [weak self] in
                    guard let self else {
                        return SecondaryMacReconciliationResult(
                            macDeviceID: mac.macDeviceID,
                            establishmentOutcome: .superseded
                        )
                    }
                    return await self.reconcileSecondaryMac(
                        mac,
                        scope: scope,
                        authorityValidation: authorityValidation,
                        allowsNewConnections: allowsNewConnections
                    )
                }
            }
            return results
        }
        guard await isAggregationScopeValid(scope) else { return }
        for result in reconciliationResults {
            guard let outcome = result.establishmentOutcome else { continue }
            recordEstablishmentOutcome(
                outcome,
                macDeviceID: result.macDeviceID
            )
        }
        if onlyMacDeviceIDs != nil, retiredControlSlot {
            // Only an actual owner retirement widens an incremental edge into
            // a full pass, so a newly free bounded slot gets its next-best
            // online Mac without repeated global work for duplicate edges.
            scheduleSecondaryAggregation()
        }
        if !allowsNewConnections {
            // A shared cooldown suppresses dialing, not ownership of the work.
            // Preserve every newly missing Mac in the existing timer's set so
            // a one-shot online/route edge cannot be lost behind another Mac's
            // backoff.
            retainSecondaryAggregationRetryEvidence(
                wanted.lazy
                    .filter { self.secondaryMacSubscriptions[$0] == nil }
                    .map(\.canonicalMacDeviceID)
            )
        }
        let allWantedConnected = wanted.allSatisfy {
            secondaryMacSubscriptions[$0] != nil
        }
        if onlyMacDeviceIDs == nil,
           allWantedConnected,
           secondaryAggregationRetryEvidenceGeneration
                == retryEvidenceGenerationAtStart {
            clearSecondaryAggregationRetryEvidence(
                for: Set(wanted.map(\.canonicalMacDeviceID))
            )
        } else if onlyMacDeviceIDs != nil,
                  allWantedConnected,
                  secondaryAggregationRetryTask == nil,
                  secondaryAggregationRetryMacIDs.isEmpty {
            secondaryAggregationRetryState.reset()
        } else if !transientFailureMacIDs.isEmpty {
            // Initial dial failures need the same shared cooldown as ended live
            // streams. Otherwise every presence heartbeat immediately retries all
            // unavailable Macs and defeats the coalesced exponential backoff.
            scheduleSecondaryAggregationRetry(
                macDeviceIDs: transientFailureMacIDs
            )
        } else if secondaryAggregationRetryTask == nil,
                  secondaryAggregationRetryMacIDs.isEmpty {
            // Every missing candidate failed an authority, route, or build
            // compatibility check. A future presence/backup/account edge can
            // attempt it again; no background timer should poll it.
            secondaryAggregationRetryState.reset()
        }
        if discoverLivePeers, onlyMacDeviceIDs == nil {
            if allowsNewConnections {
                await establishDiscoveredSecondaryIrohMacs(
                    scope: scope,
                    excluding: loadedMacs
                )
            } else {
                // Preserve the explicit foreground/refresh discovery request
                // until the shared connection cooldown permits new dials.
                secondaryIrohDiscoveryPending = true
            }
        }
    }

    /// Revalidate one warm control owner without serializing unrelated Macs.
    /// All state mutation remains MainActor-isolated; only awaited transport and
    /// store work overlaps across peers.
    private func reconcileSecondaryMac(
        _ mac: MobilePairedMac,
        scope: MobileShellScopeSnapshot,
        authorityValidation: SecondaryStoredAuthorityValidation,
        allowsNewConnections: Bool
    ) async -> SecondaryMacReconciliationResult {
        let ownerKey = MacPairingKey(mac)
        guard await isAggregationScopeValid(scope) else {
            return SecondaryMacReconciliationResult(
                macDeviceID: mac.macDeviceID,
                establishmentOutcome: .superseded
            )
        }
        if let existing = secondaryMacSubscriptions[ownerKey] {
            // Promotion owns this exact registry entry from its initial fence
            // through role commit. Aggregation defers all fetch and teardown
            // work until promotion succeeds or releases the claim.
            guard !existing.isTransitioningToFocus else {
                return SecondaryMacReconciliationResult(
                    macDeviceID: mac.macDeviceID,
                    establishmentOutcome: nil
                )
            }
            guard macInstanceTagAuthority.sameStoredAuthority(
                existing.storedInstanceTag,
                mac.instanceTag
            ) else {
                // A changed stored instance can still address the same physical
                // Iroh peer. Reserve and drain the old owner before a later pass
                // dials its replacement.
                await retireSecondaryControlOwner(
                    existing,
                    shouldRetry: allowsNewConnections
                )
                return SecondaryMacReconciliationResult(
                    macDeviceID: mac.macDeviceID,
                    establishmentOutcome: nil
                )
            }
            let refresh = enqueueSecondaryWorkspaceRefresh(
                existing,
                displayName: mac.displayName,
                authorityValidation: authorityValidation
            )
            await refresh?.value
            return SecondaryMacReconciliationResult(
                macDeviceID: mac.macDeviceID,
                establishmentOutcome: nil
            )
        }
        let outcome: SecondaryMacEstablishmentOutcome?
        if allowsNewConnections {
            outcome = await establishSecondaryMacSubscription(
                for: mac,
                scope: scope,
                authorityValidation: authorityValidation
            )
        } else {
            outcome = nil
        }
        return SecondaryMacReconciliationResult(
            macDeviceID: mac.macDeviceID,
            establishmentOutcome: outcome
        )
    }

    func readSecondaryStoredAuthority(
        macDeviceID: String,
        storedInstanceTag: String?,
        scope: MobileShellScopeSnapshot
    ) async -> SecondaryStoredAuthorityRead {
        guard let pairedMacStore else { return .revoked }
        do {
            let currentMac = try await pairedMacStore.loadAll(
                stackUserID: scope.userID,
                teamID: scope.teamID
            ).first(where: {
                MacPairingKey(
                    macDeviceID: $0.macDeviceID,
                    instanceTag: $0.instanceTag
                ) == MacPairingKey(
                    macDeviceID: macDeviceID,
                    instanceTag: storedInstanceTag
                )
            })
            guard let currentMac else { return .revoked }
            return .authorized(currentMac)
        } catch {
            return .transientFailure
        }
    }

    private func secondaryRefreshAuthorityRead(
        macDeviceID: String,
        subscription: SecondaryMacSubscription,
        scope: MobileShellScopeSnapshot,
        authorityValidation: SecondaryStoredAuthorityValidation
    ) async -> SecondaryStoredAuthorityRead {
        guard await isAggregationScopeValid(scope),
              secondaryMacSubscriptions[subscription.ownerKey] === subscription,
              await !isHiddenMacDeviceID(
                  macDeviceID,
                  instanceTag: subscription.storedInstanceTag,
                  scope: scope
              ),
              secondaryMacSubscriptions[subscription.ownerKey] === subscription else {
            return .revoked
        }
        let authorityRead: SecondaryStoredAuthorityRead
        switch authorityValidation {
        case .cached:
            if let currentMac = cachedStoredPairedMac(
                macDeviceID: macDeviceID,
                instanceTag: subscription.storedInstanceTag,
                scope: scope
            ) {
                authorityRead = .authorized(currentMac)
            } else {
                authorityRead = .revoked
            }
        case .store:
            authorityRead = await readSecondaryStoredAuthority(
                macDeviceID: macDeviceID,
                storedInstanceTag: subscription.storedInstanceTag,
                scope: scope
            )
        }
        guard secondaryMacSubscriptions[subscription.ownerKey] === subscription else {
            return .revoked
        }
        return authorityRead
    }
    private func isSecondaryMacStillVisible(
        _ macDeviceID: String,
        instanceTag: String?,
        scope: MobileShellScopeSnapshot
    ) async -> Bool {
        guard await isAggregationScopeValid(scope) else { return false }
        return await !isHiddenMacDeviceID(
            macDeviceID,
            instanceTag: instanceTag,
            scope: scope
        )
    }

    func secondaryAggregationCandidateMacIDs() async -> [String] {
        guard let pairedMacStore,
              let scope = await currentScopeSnapshot() else { return [] }
        let loadedMacs = (try? await pairedMacStore.loadAll(stackUserID: scope.userID, teamID: scope.teamID)) ?? []
        let visibleLoadedMacs = await visibleStoredPairedMacs(from: loadedMacs, scope: scope)
        guard await isAggregationScopeValid(scope) else { return [] }
        return secondaryAggregationCandidateMacs(from: visibleLoadedMacs).map(\.id)
    }

    func secondaryAggregationTargets(
        from visibleLoadedMacs: [MobilePairedMac],
        requestedCanonicalIDs: Set<String>?
    ) -> [MobilePairedMac] {
        let candidates = secondaryAggregationCandidateMacs(
            from: visibleLoadedMacs
        )
        guard let requestedCanonicalIDs else { return candidates }
        // Keep targeted online/route changes scoped to that Mac. An offline
        // edge may retire a requested owner, in which case this pass admits
        // exactly the same number of replacement candidates and no more.
        let existingControlIDs = Set(
            secondaryMacSubscriptions.keys.map(\.canonicalMacDeviceID)
        )
        let candidateIDs = Set(candidates.map {
            cmxCanonicalDeviceID($0.macDeviceID)
        })
        let requestedCandidates = candidates.filter {
            requestedCanonicalIDs.contains(cmxCanonicalDeviceID($0.macDeviceID))
        }
        let retiredRequestedOwnerCount = existingControlIDs.filter {
            requestedCanonicalIDs.contains($0) && !candidateIDs.contains($0)
        }.count
        guard retiredRequestedOwnerCount > 0 else {
            return requestedCandidates
        }
        let requestedCandidateIDs = Set(requestedCandidates.map {
            cmxCanonicalDeviceID($0.macDeviceID)
        })
        let replacements = candidates.lazy.filter { candidate in
            let candidateID = cmxCanonicalDeviceID(candidate.macDeviceID)
            return !existingControlIDs.contains(candidateID)
                && !requestedCandidateIDs.contains(candidateID)
        }.prefix(retiredRequestedOwnerCount)
        return requestedCandidates + replacements
    }

    func secondaryAggregationCandidateMacs(from visibleLoadedMacs: [MobilePairedMac]) -> [MobilePairedMac] {
        let supportedRouteKinds = runtime?.supportedRouteKinds ?? []
        // Filter exact saved instances by live presence before coalescing their
        // shared physical-Mac identity. Otherwise a fresher offline tag can win
        // coalescing and hide another paired tag that is online right now.
        let physicalAliasIDsByCanonicalID =
            physicalMacAliasCanonicalIDsByCanonicalID(
                in: visibleLoadedMacs,
                supportedKinds: supportedRouteKinds,
                preferNonLoopback: Self.prefersNonLoopbackRoutes
            )
        let exactOnlineMacs = visibleLoadedMacs.filter {
            isSecondaryMacOnlineInCurrentPresence(
                $0.macDeviceID,
                instanceTag: $0.instanceTag
            )
        }
        let exactOnlinePairingIDs = Set(exactOnlineMacs.map {
            MobilePairedMac.pairingID(
                macDeviceID: $0.macDeviceID,
                instanceTag: $0.instanceTag
            )
        })
        let onlineLoadedMacs = visibleLoadedMacs.filter {
            let canonicalID = cmxCanonicalDeviceID($0.macDeviceID)
            let pairingID = MobilePairedMac.pairingID(
                macDeviceID: $0.macDeviceID,
                instanceTag: $0.instanceTag
            )
            if exactOnlinePairingIDs.contains(pairingID) {
                // Presence distinguished multiple saved instances for the
                // same logical id. Preserve only the exact online tag.
                return isSecondaryMacOnlineInCurrentPresence(
                    $0.macDeviceID,
                    instanceTag: $0.instanceTag
                )
            }
            // A renamed/repaired row may be the currently authenticated
            // identity even though presence still names its historical id.
            // Let physical-route coalescing choose that authoritative row.
            let aliasIDs =
                physicalAliasIDsByCanonicalID[pairingID] ?? [canonicalID]
            return visibleLoadedMacs.contains { candidate in
                let candidatePairingID = MobilePairedMac.pairingID(
                    macDeviceID: candidate.macDeviceID,
                    instanceTag: candidate.instanceTag
                )
                return exactOnlinePairingIDs.contains(candidatePairingID)
                    && aliasIDs.contains(cmxCanonicalDeviceID(candidate.macDeviceID))
            }
        }
        // Sibling builds of one physical Mac are distinct aggregation targets,
        // so rows are deliberately NOT coalesced by canonical device id here;
        // dial-endpoint and Iroh-authority coalescing below still collapse
        // duplicate rows for the SAME app instance.
        let endpointDistinctMacs = Self.coalescePairedMacsByDialEndpoint(
            onlineLoadedMacs,
            supportedKinds: supportedRouteKinds,
            preferNonLoopback: Self.prefersNonLoopbackRoutes
        )
        let macs = Self.coalescePairedMacsByIrohEndpointAuthority(
            endpointDistinctMacs,
            supportedKinds: supportedRouteKinds,
            preferNonLoopback: Self.prefersNonLoopbackRoutes
        )
        // During a bounded foreground redial, `clearRemoteConnectionContext()`
        // has already nil'd `foregroundMacDeviceID`, which would make the very
        // Mac being redialed eligible as a "secondary". That opens a duplicate
        // background-control session the redial must then drain — one wasted
        // QUIC dial plus up to the handoff-drain timeout of added reconnect
        // latency. Exclude the in-flight recovery target exactly like a live
        // foreground; once recovery settles the normal exclusion (success) or
        // eligibility (terminal failure) resumes.
        let exclusionMacDeviceID: String?
        let exclusionTag: String?
        if let foregroundMacDeviceID {
            exclusionMacDeviceID = foregroundMacDeviceID
            exclusionTag = activeMacInstanceTag
        } else if isReconnectingStoredMac || connectionRecoveryOwner.isActive {
            exclusionMacDeviceID = recoveryTargetMacDeviceID
            exclusionTag = recoveryTargetInstanceTag
        } else {
            exclusionMacDeviceID = nil
            exclusionTag = nil
        }
        let foregroundIDSet: Set<String>
        if let exclusionMacDeviceID {
            let canonicalID = cmxCanonicalDeviceID(exclusionMacDeviceID)
            let foregroundPairingID = MobilePairedMac.pairingID(
                macDeviceID: exclusionMacDeviceID,
                instanceTag: exclusionTag
            )
            foregroundIDSet = physicalAliasIDsByCanonicalID[foregroundPairingID]
                ?? Set([canonicalID])
        } else {
            foregroundIDSet = []
        }
        var foregroundIrohEndpointIDs = Set<String>()
        if case let .peer(identity, _)? = activeRoute?.endpoint {
            foregroundIrohEndpointIDs.insert(
                Self.scopedIrohEndpointID(
                    endpointID: identity.endpointID,
                    instanceTag: activeMacInstanceTag
                )
            )
        }
        let activeTag = exclusionTag
        if let exclusionMacDeviceID {
            let canonicalForegroundID = cmxCanonicalDeviceID(exclusionMacDeviceID)
            // With no authenticated tag the foreground could be any of the
            // device's rows, so every row's endpoint is treated as the
            // foreground's own; with a tag, only the exact pairing's endpoints
            // are, keeping a sibling build dialable.
            for mac in visibleLoadedMacs
                where cmxCanonicalDeviceID(mac.macDeviceID) == canonicalForegroundID
                    && (activeTag == nil
                        || macInstanceTagAuthority.sameStoredAuthority(
                            mac.instanceTag,
                            activeTag
                        )) {
                if let endpointID = Self.irohEndpointID(
                    for: mac,
                    supportedKinds: supportedRouteKinds,
                    preferNonLoopback: Self.prefersNonLoopbackRoutes
                ) {
                    foregroundIrohEndpointIDs.insert(
                        Self.scopedIrohEndpointID(
                            endpointID: endpointID,
                            instanceTag: mac.instanceTag
                        )
                    )
                }
            }
        }
        let eligibleMacs = macs.filter { mac in
            guard !mac.macDeviceID.isEmpty else { return false }
            guard foregroundConnectionAttemptReservation?.conflicts(
                with: mac
            ) != true else {
                return false
            }
            if foregroundIDSet.contains(cmxCanonicalDeviceID(mac.macDeviceID)) {
                // Exclude the exact foreground pairing, and ALSO any legacy
                // untagged row on the foreground device: it names the same app
                // instance the foreground already owns, so a secondary dial
                // would duplicate-connect the live foreground. Before a tag is
                // authenticated the foreground could be any of the device's
                // rows, so the whole device is excluded.
                if activeTag == nil
                    || macInstanceTagAuthority.sameStoredAuthority(
                        mac.instanceTag,
                        activeTag
                    )
                    || mac.instanceTag == nil {
                    return false
                }
            }
            guard let endpointID = Self.irohEndpointID(
                for: mac,
                supportedKinds: supportedRouteKinds,
                preferNonLoopback: Self.prefersNonLoopbackRoutes
            ) else {
                // `makeSecondaryClient` still supports an authorized legacy
                // Tailscale route. Iroh support on the runtime is global and
                // must not disqualify an individual pre-Iroh pairing.
                return true
            }
            return !foregroundIrohEndpointIDs.contains(
                Self.scopedIrohEndpointID(
                    endpointID: endpointID,
                    instanceTag: mac.instanceTag
                )
            )
        }
        let existingControlOwnerKeys = Set(secondaryMacSubscriptions.keys)
        return Array(eligibleMacs.sorted { lhs, rhs in
            let lhsIsWarm = existingControlOwnerKeys.contains(MacPairingKey(lhs))
            let rhsIsWarm = existingControlOwnerKeys.contains(MacPairingKey(rhs))
            if lhsIsWarm != rhsIsWarm { return lhsIsWarm }
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            if lhs.lastSeenAt != rhs.lastSeenAt {
                return lhs.lastSeenAt > rhs.lastSeenAt
            }
            if lhs.macDeviceID != rhs.macDeviceID {
                return cmxCanonicalDeviceID(lhs.macDeviceID)
                    < cmxCanonicalDeviceID(rhs.macDeviceID)
            }
            return (lhs.instanceTag ?? "") < (rhs.instanceTag ?? "")
        }.prefix(Self.maximumWarmControlConnectionCount))
    }

    private func isSecondaryMacOnlineInCurrentPresence(
        _ macDeviceID: String,
        instanceTag: String?
    ) -> Bool {
        guard presence != nil else { return true }
        // Presence is snapshot-first. Before that snapshot absence is unknown,
        // so keep candidates under the fixed pool cap. Afterward the snapshot
        // is authoritative and an absent logical Mac is offline.
        guard presenceMap.hasReceivedSnapshot else { return true }
        return presenceSummary(
            for: macDeviceID,
            instanceTag: instanceTag
        )?.online == true
    }

    /// Revalidate a selected physical Mac after its dial suspends. An exact
    /// presence record wins, including a newer offline edge. When the
    /// authenticated row has no exact record yet, accept an online stored row
    /// in the same physical-route alias component.
    private func isSecondaryMacOrPhysicalAliasOnlineInCurrentPresence(
        _ macDeviceID: String,
        instanceTag: String?,
        scope: MobileShellScopeSnapshot
    ) -> Bool {
        guard presence != nil else { return true }
        guard presenceMap.hasReceivedSnapshot else { return true }
        let exactSummary = if let instanceTag {
            presenceMap.instanceSummary(
                deviceId: macDeviceID,
                tag: instanceTag
            )
        } else {
            presenceMap.soleInstanceSummary(deviceId: macDeviceID)
        }
        if let exactSummary {
            return exactSummary.online
        }
        guard storedPairedMacCacheScope == scope else { return false }
        let pairingID = MobilePairedMac.pairingID(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        let aliasCanonicalIDs =
            storedPairedMacAliasCanonicalIDsByCanonicalID[pairingID]
                ?? [cmxCanonicalDeviceID(macDeviceID)]
        return aliasCanonicalIDs.contains { aliasCanonicalID in
            (storedPairedMacsByCanonicalDeviceID[aliasCanonicalID] ?? [])
                .contains { storedMac in
                    guard macInstanceTagAuthority.sameStoredAuthority(
                        storedMac.instanceTag,
                        instanceTag
                    ) else { return false }
                    if let storedTag = storedMac.instanceTag {
                        return presenceMap.instanceSummary(
                            deviceId: storedMac.macDeviceID,
                            tag: storedTag
                        )?.online == true
                    }
                    return presenceMap.soleInstanceSummary(
                        deviceId: storedMac.macDeviceID
                    )?.online == true
                }
        }
    }

    /// Open a persistent read-only connection to `mac`, seed its workspace state,
    /// then run a live `workspace.updated` consumer that re-fetches its list on
    /// each change. Fully best-effort: on any failure the entry is torn down and
    /// the pull-to-refresh / foreground re-aggregate path remains the fallback, so
    /// a secondary subscription can never crash or block the foreground.
    func establishSecondaryMacSubscription(
        for mac: MobilePairedMac,
        scope: MobileShellScopeSnapshot,
        authorityValidation: SecondaryStoredAuthorityValidation,
        persistAuthenticatedDiscovery: Bool = false
    ) async -> SecondaryMacEstablishmentOutcome {
        let flightKey = MacPairingKey(mac)
        if let existing = secondaryMacEstablishmentFlights[flightKey] {
            MobileDebugLog.anchormux(
                "CMUX_CONNECT secondary_dial_join mac=\(mac.macDeviceID.prefix(8)) tag=\(mac.instanceTag ?? "-")"
            )
            return await existing.task.value
        }
        let dialStart = ContinuousClock.now
        MobileDebugLog.anchormux(
            "CMUX_CONNECT secondary_dial_start mac=\(mac.macDeviceID.prefix(8)) tag=\(mac.instanceTag ?? "-")"
        )
        let flightID = UUID()
        let task = Task { @MainActor [weak self] in
            defer {
                if let self,
                   self.secondaryMacEstablishmentFlights[flightKey]?.id
                       == flightID {
                    self.secondaryMacEstablishmentFlights[flightKey] = nil
                    if Task.isCancelled, self.foregroundRefreshIsActive {
                        self.scheduleSecondaryAggregation()
                    }
                }
            }
            guard let self else {
                return SecondaryMacEstablishmentOutcome.superseded
            }
            return await self.performSecondaryMacSubscriptionEstablishment(
                for: mac,
                scope: scope,
                authorityValidation: authorityValidation,
                persistAuthenticatedDiscovery: persistAuthenticatedDiscovery
            )
        }
        secondaryMacEstablishmentFlights[flightKey] =
            SecondaryMacEstablishmentFlight(
                id: flightID,
                mac: mac,
                task: task
            )
        let outcome = await task.value
        let elapsed = dialStart.duration(to: .now)
        // attoseconds (1e-18 s) -> milliseconds (1e-3 s): divide by 1e15.
        let elapsedMilliseconds = elapsed.components.seconds * 1000
            + elapsed.components.attoseconds / 1_000_000_000_000_000
        MobileDebugLog.anchormux(
            "CMUX_CONNECT secondary_dial_end mac=\(mac.macDeviceID.prefix(8)) tag=\(mac.instanceTag ?? "-") outcome=\(String(describing: outcome)) elapsed_ms=\(elapsedMilliseconds)"
        )
        return outcome
    }

    private func performSecondaryMacSubscriptionEstablishment(
        for mac: MobilePairedMac,
        scope: MobileShellScopeSnapshot,
        authorityValidation: SecondaryStoredAuthorityValidation,
        persistAuthenticatedDiscovery: Bool
    ) async -> SecondaryMacEstablishmentOutcome {
        let macID = mac.macDeviceID
        let pairingKey = MacPairingKey(mac)
        guard let pairedMacStore,
              foregroundRefreshIsActive,
              !Task.isCancelled,
              foregroundConnectionAttemptReservation?.conflicts(
                  with: mac
              ) != true,
              secondaryMacSubscriptions[pairingKey] == nil,
              secondaryMacDrainReservation(onDeviceOf: pairingKey) == nil else {
            return .superseded
        }
        let handle: SecondaryClientHandle
        switch await makeSecondaryClient(for: mac) {
        case let .connected(connectedHandle):
            handle = connectedHandle
        case .transientFailure:
            guard await isSecondaryMacStillVisible(
                macID,
                instanceTag: mac.instanceTag,
                scope: scope
            ) else {
                return .superseded
            }
            markSecondaryMacUnavailableIfUnowned(pairingKey)
            return .transientFailure
        case .permanentFailure:
            guard await isSecondaryMacStillVisible(
                macID,
                instanceTag: mac.instanceTag,
                scope: scope
            ) else {
                return .superseded
            }
            markSecondaryMacUnavailableIfUnowned(pairingKey)
            return .permanentFailure
        }
        let client = handle.client
        MobileDebugLog.anchormux(
            "CMUX_CONNECT secondary_client_connected mac=\(macID.prefix(8)) tag=\(mac.instanceTag ?? "-")"
        )
        // Re-check after the async client build so a concurrent refresh cannot
        // open a duplicate connection, AND so a sign-out / account/team switch
        // during the connect does not leave an old-scope connection live or write
        // its state; the loser disconnects its client.
        guard !Task.isCancelled,
              foregroundRefreshIsActive,
              foregroundConnectionAttemptReservation?.conflicts(
                  with: mac
              ) != true,
              secondaryMacSubscriptions[pairingKey] == nil,
              secondaryMacDrainReservation(onDeviceOf: pairingKey) == nil,
              macConnectionRegistry.sessionCount
                  < Self.maximumLiveMacConnectionCount,
              await isSecondaryMacStillVisible(
                  macID,
                  instanceTag: mac.instanceTag,
                  scope: scope
              ) else {
            await disconnectSecondaryClientAndDrain(client)
            return .superseded
        }
        if persistAuthenticatedDiscovery {
            let accepted = await persistPairedMacFromTicket(
                handle.ticket,
                instanceTagUpdate: .replace(
                    handle.authenticatedInstanceTag
                        ?? handle.storedInstanceTag
                ),
                displayNameOverride: mac.displayName,
                markActive: false,
                requiredScope: scope
            )
            guard accepted,
                  !Task.isCancelled,
                  await isAggregationScopeValid(scope) else {
                await disconnectSecondaryClientAndDrain(client)
                return .superseded
            }
        }
        // Targeted presence passes use the scoped cache to select a bounded
        // candidate set, but a dial crosses several suspension points. Read the
        // current store immediately before publication so a removed or replaced
        // app instance cannot become authoritative from the older cache.
        let currentMac: MobilePairedMac?
        do {
            currentMac = try await pairedMacStore.loadAll(
                stackUserID: scope.userID,
                teamID: scope.teamID
            ).first(where: {
                MacPairingKey(
                    macDeviceID: $0.macDeviceID,
                    instanceTag: $0.instanceTag
                ) == MacPairingKey(
                    macDeviceID: macID,
                    instanceTag: handle.storedInstanceTag
                )
            })
        } catch {
            await disconnectSecondaryClientAndDrain(client)
            guard await isAggregationScopeValid(scope) else {
                return .superseded
            }
            markSecondaryMacUnavailableIfUnowned(pairingKey)
            return .transientFailure
        }
        let ownerKey = MacPairingKey(
            macDeviceID: macID,
            instanceTag: handle.storedInstanceTag
        )
        guard !Task.isCancelled,
              secondaryMacSubscriptions[ownerKey] == nil,
              secondaryMacDrainReservation(onDeviceOf: ownerKey) == nil,
              await isSecondaryMacStillVisible(
                  macID,
                  instanceTag: handle.storedInstanceTag,
                  scope: scope
              ) else {
            await disconnectSecondaryClientAndDrain(client)
            return .superseded
        }
        guard let currentMac,
              macInstanceTagAuthority.sameStoredAuthority(
                  currentMac.instanceTag,
                  handle.storedInstanceTag
              ) else {
            markSecondaryMacUnavailableIfUnowned(ownerKey)
            await disconnectSecondaryClientAndDrain(client)
            return .permanentFailure
        }
        // Presence reconciliation may run while the client is dialing.
        // Revalidate synchronously at publication so an offline edge that
        // observed no owner cannot be overwritten by the old pass.
        if !persistAuthenticatedDiscovery {
            guard isSecondaryMacOrPhysicalAliasOnlineInCurrentPresence(
                macID,
                instanceTag: handle.storedInstanceTag,
                scope: scope
            ) else {
                markSecondaryMacUnavailableIfUnowned(ownerKey)
                await disconnectSecondaryClientAndDrain(client)
                return .superseded
            }
        }
        let subscription = SecondaryMacSubscription(
            macDeviceID: macID,
            client: client,
            route: handle.route,
            ticket: handle.ticket,
            storedInstanceTag: handle.storedInstanceTag,
            authenticatedInstanceTag: handle.authenticatedInstanceTag,
            supportedHostCapabilities: handle.supportedHostCapabilities,
            actionCapabilities: handle.actionCapabilities,
            displayName: mac.displayName
        )
        guard foregroundConnectionAttemptReservation?.conflicts(
                  with: currentMac
              ) != true,
              secondaryMacDrainReservation(onDeviceOf: ownerKey) == nil,
              macConnectionRegistry.insertControlIfAbsent(
                  subscription,
                  maximumControlCount:
                      Self.maximumWarmControlConnectionCount
              ) else {
            await disconnectSecondaryClientAndDrain(client)
            return .superseded
        }
        let displayName = mac.displayName
        guard let initialRefresh = enqueueSecondaryWorkspaceRefresh(
            subscription,
            displayName: displayName,
            authorityValidation: authorityValidation
        ) else {
            return .superseded
        }
        await initialRefresh.value
        guard await isAggregationScopeValid(scope) else {
            return .superseded
        }
        guard secondaryMacSubscriptions[ownerKey] === subscription,
              !subscription.isTransitioningToFocus else {
            return .superseded
        }
        guard workspacesByMac[ownerKey]?.status == .connected else {
            return .transientFailure
        }
        await flushPendingNotificationDismisses(
            macDeviceID: ownerKey.canonicalMacDeviceID,
            instanceTag: ownerKey.normalizedInstanceTag
        )
        startSecondaryControlMaintenance(
            subscription,
            displayName: displayName
        )
        return .connected
    }

    /// Start the maintenance mode supported by this exact host. Current Macs
    /// receive live control events; legacy Macs stay warm through the bounded
    /// shared refresh cadence without attempting an unsupported subscription.
    func startSecondaryControlMaintenance(
        _ subscription: SecondaryMacSubscription,
        displayName: String?
    ) {
        guard secondaryMacSubscriptions[subscription.ownerKey]
                === subscription else {
            return
        }
        scheduleSecondaryNotificationFeedRefresh(
            macDeviceID: subscription.ownerKey.pairingID,
            client: subscription.client,
            displayName: displayName
        )
        if subscription.supportedHostCapabilities.contains("events.v1") {
            startSecondaryEventConsumer(
                subscription,
                displayName: displayName
            )
        }
        ensureSecondaryControlKeepalive()
    }

    /// Start one lightweight aggregate-state consumer. This path never includes
    /// terminal bytes or render-grid topics.
    func startSecondaryEventConsumer(
        _ subscription: SecondaryMacSubscription,
        displayName: String?
    ) {
        let ownerKey = subscription.ownerKey
        let client = subscription.client
        let subscriptionID = ObjectIdentifier(subscription)
        subscription.task = Task { @MainActor [weak self] in
            let stream = await client.subscribe(to: SecondaryMacSubscription.eventTopics)
            guard let activation =
                await self?.enableOwnedSecondaryEventSubscription(
                    subscription
                ) else {
                return
            }
            switch activation {
            case .active:
                break
            case .transientFailure:
                await self?.handleSecondaryControlStreamEnded(
                    ownerKey: ownerKey,
                    subscriptionID: subscriptionID,
                    client: client,
                    shouldRetry: true
                )
                return
            case .permanentFailure:
                await self?.handleSecondaryControlStreamEnded(
                    ownerKey: ownerKey,
                    subscriptionID: subscriptionID,
                    client: client,
                    shouldRetry: false
                )
                return
            case .superseded:
                return
            }
            self?.ensureSecondaryControlKeepalive()
            for await event in stream {
                guard !Task.isCancelled else { break }
                // Stop if this subscription was replaced/torn down.
                guard self?.handleSecondaryControlEvent(
                    event,
                    ownerKey: ownerKey,
                    subscriptionID: subscriptionID,
                    client: client,
                    displayName: displayName
                ) == true else { break }
            }
            await self?.handleSecondaryControlStreamEnded(
                ownerKey: ownerKey,
                subscriptionID: subscriptionID,
                client: client,
                shouldRetry: true
            )
        }
    }

    private func handleSecondaryControlEvent(
        _ event: MobileEventEnvelope,
        ownerKey: MacPairingKey,
        subscriptionID: ObjectIdentifier,
        client: MobileCoreRPCClient,
        displayName: String?
    ) -> Bool {
        guard let subscription = secondaryMacSubscriptions[ownerKey],
              ObjectIdentifier(subscription) == subscriptionID,
              subscription.client === client else {
            return false
        }
        // The focused listener consumes these same topics on a multiplexed
        // client. Keep its control stream warm without scheduling duplicate
        // workspace and notification repairs until this peer leaves focus.
        if client === remoteClient { return true }
        if event.topic == "workspace.updated" {
            // Coalesced, newest-wins refresh: a title/progress churn stream
            // collapses to at most one in-flight + one trailing full-list scan.
            // Secondary clients intentionally do not subscribe to
            // `mobile.sync.delta` until they own independent per-Mac v2 mirrors;
            // consuming both host signals would duplicate every refresh.
            scheduleSecondaryRefresh(
                ownerKey: ownerKey,
                client: client,
                displayName: displayName
            )
        } else if event.topic == "notification.feed.changed" {
            handleNotificationFeedChangedEvent(
                event,
                macDeviceID: ownerKey.pairingID,
                client: client,
                displayName: notificationFeedDisplayNameForSecondary(
                    macDeviceID: ownerKey.pairingID,
                    fallback: displayName
                )
            )
        }
        return true
    }

    private func ensureSecondaryControlKeepalive() {
        guard foregroundRefreshIsActive,
              secondaryControlKeepaliveTask == nil else { return }
        let clock = controlPlaneSchedulingClock
        let taskGeneration = UUID()
        secondaryControlKeepaliveTaskGeneration = taskGeneration
        secondaryControlKeepaliveTask = Task { @MainActor [weak self] in
            var ticksSinceRefreshOnlyHealthCheck = 0
            defer {
                if let self,
                   self.secondaryControlKeepaliveTaskGeneration
                    == taskGeneration {
                    self.secondaryControlKeepaliveTask = nil
                }
            }
            while !Task.isCancelled {
                do {
                    // Controlled exception: CGNAT can silently expire otherwise
                    // healthy UDP paths. One shared 20-second tick covers only
                    // presence-confirmed online Macs and carries no render data.
                    try await clock.sleep(for: .seconds(20))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      let self else {
                    return
                }
                ticksSinceRefreshOnlyHealthCheck += 1
                let refreshOnlyHealthCheckIsDue =
                    ticksSinceRefreshOnlyHealthCheck >= 3
                if refreshOnlyHealthCheckIsDue {
                    ticksSinceRefreshOnlyHealthCheck = 0
                }
                let stillHasControlConnections =
                    await self.reassertSecondaryControlSubscriptions(
                        refreshOnlyHealthCheckIsDue:
                            refreshOnlyHealthCheckIsDue
                    )
                guard !Task.isCancelled, stillHasControlConnections else {
                    return
                }
            }
        }
    }

    private func reassertSecondaryControlSubscriptions(
        refreshOnlyHealthCheckIsDue: Bool
    ) async -> Bool {
        let subscriptions = Array(secondaryMacSubscriptions)
        guard !subscriptions.isEmpty else { return false }
        let reassertions = subscriptions.map { _, subscription in
            Task { @MainActor [weak self] in
                await self?.reassertSecondaryControlSubscription(
                    subscription: subscription,
                    refreshOnlyHealthCheckIsDue:
                        refreshOnlyHealthCheckIsDue
                )
            }
        }
        await withTaskCancellationHandler {
            for reassertion in reassertions {
                await reassertion.value
            }
        } onCancel: {
            for reassertion in reassertions {
                reassertion.cancel()
            }
        }
        return !secondaryMacSubscriptions.isEmpty
    }

    private func reassertSecondaryControlSubscription(
        subscription: SecondaryMacSubscription,
        refreshOnlyHealthCheckIsDue: Bool
    ) async {
        let ownerKey = subscription.ownerKey
        guard !Task.isCancelled,
              secondaryMacSubscriptions[ownerKey] === subscription,
              !subscription.isTransitioningToFocus else {
            return
        }
        guard subscription.supportedHostCapabilities
                .contains("events.v1") else {
            if refreshOnlyHealthCheckIsDue {
                enqueueSecondaryWorkspaceRefresh(
                    subscription,
                    displayName: subscription.displayName
                )
                scheduleSecondaryNotificationFeedRefresh(
                    macDeviceID: ownerKey.pairingID,
                    client: subscription.client,
                    displayName: subscription.displayName
                )
            }
            return
        }
        guard subscription.hasActivatedControlStream else { return }
        let activation = await enableOwnedSecondaryEventSubscription(
            subscription
        )
        // Promotion may have fenced this subscription while the reassertion
        // was awaiting its acknowledgement. It will drain this task and issue
        // the final unsubscribe, so neither result owns teardown.
        guard secondaryMacSubscriptions[ownerKey] === subscription,
              !subscription.isTransitioningToFocus else {
            return
        }
        switch activation {
        case .active, .superseded:
            return
        case .transientFailure:
            await handleSecondaryControlStreamEnded(
                ownerKey: ownerKey,
                subscriptionID: ObjectIdentifier(subscription),
                client: subscription.client,
                shouldRetry: true
            )
        case .permanentFailure:
            await handleSecondaryControlStreamEnded(
                ownerKey: ownerKey,
                subscriptionID: ObjectIdentifier(subscription),
                client: subscription.client,
                shouldRetry: false
            )
        }
    }

    /// Start or reassert one control stream only while this exact registry
    /// owner remains control-only. The retained operation covers first
    /// activation and keepalives, so promotion can drain either before its
    /// final unsubscribe.
    private func enableOwnedSecondaryEventSubscription(
        _ subscription: SecondaryMacSubscription
    ) async -> SecondaryOwnedEventSubscriptionActivation {
        let ownerKey = subscription.ownerKey
        guard secondaryMacSubscriptions[ownerKey] === subscription,
              !subscription.isTransitioningToFocus else {
            return .superseded
        }
        let subscriptionID = ObjectIdentifier(subscription)
        if let existing =
            secondaryControlReassertionTasksByOwnerKey[ownerKey] {
            let existingOwnerID =
                secondaryControlReassertionOwnerIDsByOwnerKey[ownerKey]
            let existingToken =
                secondaryControlReassertionTokensByOwnerKey[ownerKey]
            let activation = await existing.value
            guard secondaryMacSubscriptions[ownerKey] === subscription,
                  !subscription.isTransitioningToFocus else {
                return .superseded
            }
            if existingOwnerID == subscriptionID {
                if case .active = activation {
                    subscription.hasActivatedControlStream = true
                }
                return activation
            }
            // A replaced owner published the current single-flight before this
            // subscription was installed. Remove only that completed flight,
            // then let the new owner publish its own activation.
            if secondaryControlReassertionTokensByOwnerKey[ownerKey]
                == existingToken {
                secondaryControlReassertionTasksByOwnerKey[ownerKey] = nil
                secondaryControlReassertionTokensByOwnerKey[ownerKey] = nil
                secondaryControlReassertionOwnerIDsByOwnerKey[ownerKey] = nil
            }
        }
        // No suspension occurs between the ownership guard and publishing this
        // task. Promotion therefore either fences us out or can await the exact
        // RPC that already owns activation.
        let requiresInitialCatchUp =
            !subscription.hasActivatedControlStream
        let operation = Task { @MainActor [weak self] in
            guard let self else {
                return SecondaryOwnedEventSubscriptionActivation.superseded
            }
            let activation = await self.enableSecondaryEventSubscription(
                on: subscription.client,
                streamID: subscription.streamID
            )
            guard self.secondaryMacSubscriptions[ownerKey] === subscription,
                  !subscription.isTransitioningToFocus else {
                return .superseded
            }
            switch activation {
            case .transientFailure:
                return .transientFailure
            case .permanentFailure:
                return .permanentFailure
            case let .active(requiresCatchUp):
                guard requiresInitialCatchUp || requiresCatchUp else {
                    return .active
                }
                let reconciled =
                    await self.reconcileSecondaryControlGap(subscription)
                if reconciled {
                    return .active
                }
                // Workspace repair owns teardown when it fails. A feed-only
                // repair failure can leave this same registry owner installed,
                // so preserve the prior retry behavior for that live client.
                return self.secondaryMacSubscriptions[ownerKey]
                        === subscription
                    && !subscription.isTransitioningToFocus
                    ? .transientFailure
                    : .superseded
            }
        }
        let operationToken = UUID()
        secondaryControlReassertionTasksByOwnerKey[ownerKey] = operation
        secondaryControlReassertionTokensByOwnerKey[ownerKey] = operationToken
        secondaryControlReassertionOwnerIDsByOwnerKey[ownerKey] =
            subscriptionID
        let activation = await operation.value
        if secondaryControlReassertionTokensByOwnerKey[ownerKey]
            == operationToken {
            secondaryControlReassertionTasksByOwnerKey[ownerKey] = nil
            secondaryControlReassertionTokensByOwnerKey[ownerKey] = nil
            secondaryControlReassertionOwnerIDsByOwnerKey[ownerKey] = nil
        }
        guard secondaryMacSubscriptions[ownerKey] === subscription,
              !subscription.isTransitioningToFocus else {
            return .superseded
        }
        if case .active = activation {
            subscription.hasActivatedControlStream = true
        }
        return activation
    }

    /// Repair workspace and notification events emitted before the host
    /// recreated this control registration. The activation task owns this work,
    /// so promotion drains the complete subscribe-plus-catch-up operation.
    private func reconcileSecondaryControlGap(
        _ subscription: SecondaryMacSubscription
    ) async -> Bool {
        let ownerKey = subscription.ownerKey
        // Direct unit fixtures can install a subscription without the
        // account-scoped paired store. Production pool entries always have it.
        guard pairedMacStore != nil else { return true }
        guard secondaryMacSubscriptions[ownerKey] === subscription,
              !subscription.isTransitioningToFocus else {
            return false
        }
        guard let refresh = enqueueSecondaryWorkspaceRefresh(
            subscription,
            displayName: subscription.displayName
        ) else {
            return false
        }
        await refresh.value
        guard secondaryMacSubscriptions[ownerKey] === subscription,
              !subscription.isTransitioningToFocus,
              workspacesByMac[ownerKey]?.status == .connected else {
            return false
        }
        guard await reconcileSecondaryNotificationFeedAfterControlGap(
            macDeviceID: ownerKey.pairingID,
            client: subscription.client,
            displayName: subscription.displayName
        ) else {
            return false
        }
        return secondaryMacSubscriptions[ownerKey] === subscription
            && !subscription.isTransitioningToFocus
    }

    /// Fence a control subscription out of the shared keepalive before
    /// promotion sends its unsubscribe. The in-flight RPC settles before the
    /// timer owner is canceled, making the subsequent unsubscribe the final
    /// server-side operation for this stream id.
    func prepareSecondarySubscriptionForPromotion(
        _ subscription: SecondaryMacSubscription
    ) async -> Bool {
        let ownerKey = subscription.ownerKey
        guard secondaryMacSubscriptions[ownerKey] === subscription,
              !subscription.isTransitioningToFocus else {
            return false
        }
        subscription.isTransitioningToFocus = true
        let workspaceRefresh = subscription.refreshTask
        await workspaceRefresh?.value
        guard secondaryMacSubscriptions[ownerKey] === subscription else {
            return false
        }
        guard subscription.supportedHostCapabilities.contains("events.v1")
        else {
            return true
        }
        // Drain the target's current reassertion while its timer owner remains
        // uncancelled. Canceling first can make an RPC await return locally
        // before the server has finished applying the subscribe.
        if let reassertion =
            secondaryControlReassertionTasksByOwnerKey[ownerKey] {
            let drain = await Self.raceAgainstDeadline(
                nanoseconds: connectionHandoffDrainTimeoutNanoseconds
            ) {
                _ = await reassertion.value
                return true
            }
            guard drain.value == true,
                  !drain.wasCancelled,
                  secondaryMacSubscriptions[ownerKey] === subscription else {
                // A timed-out or cancelled reassertion may already have
                // reached the host. It cannot safely return to control
                // ownership, because a later acknowledgement could recreate
                // that stream after another role transition.
                await retireSecondaryPromotionCandidate(subscription)
                return false
            }
        }
        let keepalive = secondaryControlKeepaliveTask
        secondaryControlKeepaliveTaskGeneration = UUID()
        secondaryControlKeepaliveTask = nil
        keepalive?.cancel()
        // The target's keyed operation is drained above. Do not await the
        // shared timer owner because it may still be awaiting an unrelated
        // Mac's reassertion; cancellation fences it from reaching the target.
        // Resume the shared owner for every other control connection. The
        // promoting target remains fenced and is skipped by each tick.
        if !secondaryMacSubscriptions.isEmpty {
            ensureSecondaryControlKeepalive()
        }
        guard secondaryMacSubscriptions[ownerKey] === subscription else {
            return false
        }
        return true
    }

    /// Promotion was superseded before its unsubscribe. Return the target to
    /// ordinary control ownership and restart the one shared keepalive timer.
    func resumeSecondarySubscriptionAfterAbortedPromotion(
        _ subscription: SecondaryMacSubscription
    ) async {
        let ownerKey = subscription.ownerKey
        guard secondaryMacSubscriptions[ownerKey] === subscription else {
            return
        }
        if subscription.eventStreamEndedDuringFocusTransition {
            await retireSecondaryControlOwner(
                subscription,
                shouldRetry: true
            )
            return
        }
        subscription.isTransitioningToFocus = false
        // Control events are consumed while the promotion fence is active, but
        // notification routing deliberately rejects that transitioning owner.
        // One coalesced list fetch repairs any invalidation consumed in that gap.
        scheduleSecondaryNotificationFeedRefresh(
            macDeviceID: ownerKey.pairingID,
            client: subscription.client,
            displayName: subscription.displayName
        )
        if subscription.refreshPending,
           subscription.refreshTask == nil,
           subscription.deferredRefreshTask == nil {
            scheduleDeferredSecondaryWorkspaceRefresh(
                subscription,
                displayName: subscription.displayName
            )
        }
        ensureSecondaryControlKeepalive()
        scheduleSecondaryPresenceAggregation(
            forMacDeviceID: subscription.macDeviceID
        )
    }

    private func handleSecondaryControlStreamEnded(
        ownerKey: MacPairingKey,
        subscriptionID: ObjectIdentifier,
        client: MobileCoreRPCClient,
        shouldRetry: Bool
    ) async {
        guard let subscription = secondaryMacSubscriptions[ownerKey],
              ObjectIdentifier(subscription) == subscriptionID,
              subscription.client === client else { return }
        guard !subscription.isTransitioningToFocus else {
            subscription.eventStreamEndedDuringFocusTransition = true
            return
        }
        await retireSecondaryControlOwner(
            subscription,
            shouldRetry: shouldRetry
        )
    }

    func scheduleSecondaryAggregationRetry(
        macDeviceIDs: Set<String>,
        needsFullRefresh: Bool = false
    ) {
        retainSecondaryAggregationRetryEvidence(
            macDeviceIDs.map(cmxCanonicalDeviceID)
        )
        if needsFullRefresh {
            secondaryAggregationRetryNeedsFullRefresh =
                true
        }
        guard presence != nil,
              foregroundRefreshIsActive,
              secondaryAggregationRetryTask == nil,
              (!secondaryAggregationRetryMacIDs.isEmpty
                  || secondaryAggregationRetryNeedsFullRefresh),
              isSignedIn else {
            return
        }
        guard let delay = secondaryAggregationRetryState.schedule() else { return }
        let clock = controlPlaneSchedulingClock
        let taskGeneration = UUID()
        secondaryAggregationRetryTaskGeneration = taskGeneration
        secondaryAggregationRetryTask = Task { @MainActor [weak self] in
            do {
                // One-shot backoff, not polling: presence pushes share this
                // single pending retry and cannot fan out per-Mac dial loops.
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.secondaryAggregationRetryTaskGeneration
                    == taskGeneration else {
                return
            }
            self.secondaryAggregationRetryState.fire()
            self.secondaryAggregationRetryTask = nil
            let macDeviceIDs = self.secondaryAggregationRetryMacIDs
            self.secondaryAggregationRetryMacIDs = []
            let needsFullRefresh =
                self.secondaryAggregationRetryNeedsFullRefresh
            self.secondaryAggregationRetryNeedsFullRefresh = false
            if needsFullRefresh {
                self.scheduleSecondaryAggregation()
            } else {
                for macDeviceID in macDeviceIDs {
                    self.scheduleSecondaryPresenceAggregation(
                        forMacDeviceID: macDeviceID
                    )
                }
            }
        }
    }

    func cancelSecondaryAggregationRetry() {
        secondaryAggregationRetryEvidenceGeneration &+= 1
        secondaryAggregationRetryTaskGeneration = UUID()
        secondaryAggregationRetryTask?.cancel()
        secondaryAggregationRetryTask = nil
        secondaryAggregationRetryMacIDs = []
        secondaryAggregationRetryNeedsFullRefresh = false
        secondaryAggregationRetryState.reset()
    }

    private func retainSecondaryAggregationRetryEvidence<S: Sequence>(
        _ macDeviceIDs: S
    ) where S.Element == String {
        let canonicalIDs = Set(macDeviceIDs.map(cmxCanonicalDeviceID))
        guard !canonicalIDs.isEmpty else { return }
        secondaryAggregationRetryEvidenceGeneration &+= 1
        secondaryAggregationRetryMacIDs.formUnion(canonicalIDs)
    }

    private func clearSecondaryAggregationRetryEvidence(
        for macDeviceIDs: Set<String>
    ) {
        secondaryAggregationRetryMacIDs.subtract(
            macDeviceIDs.map(cmxCanonicalDeviceID)
        )
        guard secondaryAggregationRetryMacIDs.isEmpty else { return }
        cancelSecondaryAggregationRetry()
    }

    /// Downgrade retained secondary rows without dropping them from the
    /// aggregate. A failed refresh/reconnect should make stale rows visibly
    /// unavailable, not leave them connected/actionable until a stream callback
    /// happens to run.
    func markSecondaryMacUnavailable(_ ownerKey: MacPairingKey) {
        guard var state = workspacesByMac[ownerKey] else { return }
        state.status = .unavailable
        state.workspaceGroupsAreAuthoritative = false
        workspacesByMac[ownerKey] = state
    }

    func markSecondaryMacUnavailableIfUnowned(_ ownerKey: MacPairingKey) {
        guard !liveMacConnections.contains(where: {
            $0.id == ownerKey.pairingID
        }) else {
            return
        }
        markSecondaryMacUnavailable(ownerKey)
    }

    /// Stop only foreground-owned aggregation work when iOS backgrounds the
    /// process. Established control sessions remain pooled, but no unfinished
    /// refresh or establishment flight may retain a physical Iroh dial across
    /// suspension and poison the next foreground recovery.
    func suspendSecondaryConnectionEstablishmentForBackground() {
        secondaryAggregationTaskGeneration = UUID()
        secondaryAggregationTask?.cancel()
        secondaryAggregationTask = nil
        secondaryAggregationPending = false
        // Foreground always performs one authenticated discovery pass. Keep
        // that intent even if backgrounding cancelled the pass that owned it.
        secondaryIrohDiscoveryPending = true

        secondaryPresenceAggregationTaskGeneration = UUID()
        secondaryPresenceAggregationTask?.cancel()
        secondaryPresenceAggregationTask = nil
        secondaryPresencePendingMacIDs = []

        // Keep canceled flights registered until their transport cleanup has
        // settled. Foreground connection recovery waits on conflicting flights
        // before dialing, so it cannot race a stale route lease.
        let establishmentFlights = Array(secondaryMacEstablishmentFlights.values)
        for flight in establishmentFlights {
            flight.task.cancel()
        }

        secondaryAggregationAfterPushedRoutesOperationID = UUID()
        secondaryAggregationAfterPushedRoutesTask?.cancel()
        secondaryAggregationAfterPushedRoutesTask = nil
        secondaryAggregationAfterPushedRoutesScope = nil
        secondaryAggregationAfterPushedRoutesMacIDs = []
        secondaryAggregationAfterPushedRoutesNeedsFullRefresh = false
        cancelSecondaryAggregationRetry()

        secondaryControlKeepaliveTaskGeneration = UUID()
        secondaryControlKeepaliveTask?.cancel()
        secondaryControlKeepaliveTask = nil
        for task in secondaryControlReassertionTasksByOwnerKey.values {
            task.cancel()
        }
        secondaryControlReassertionTasksByOwnerKey = [:]
        secondaryControlReassertionTokensByOwnerKey = [:]
        secondaryControlReassertionOwnerIDsByOwnerKey = [:]
    }

    /// Resume the one shared maintenance owner for control sessions that
    /// survived suspension. The normal foreground aggregation pass separately
    /// probes and replaces any sessions that did not survive.
    func resumeSecondaryControlMaintenanceAfterForeground() {
        guard foregroundRefreshIsActive,
              !secondaryMacSubscriptions.isEmpty else { return }
        ensureSecondaryControlKeepalive()
    }

    /// Enqueue one per-Mac workspace refresh. Presence reconciliation, event
    /// catch-up, mutation repair, and refresh-only health checks all share this
    /// single owner, so responses are applied in request order and a superseded
    /// failure cannot tear down a client that a newer request refreshed.
    @discardableResult
    private func enqueueSecondaryWorkspaceRefresh(
        _ subscription: SecondaryMacSubscription,
        displayName: String?,
        authorityValidation: SecondaryStoredAuthorityValidation = .store
    ) -> Task<Void, Never>? {
        let macID = subscription.macDeviceID
        let ownerKey = subscription.ownerKey
        guard secondaryMacSubscriptions[ownerKey] === subscription,
              !subscription.isTransitioningToFocus else {
            return nil
        }
        subscription.workspaceRefreshGeneration &+= 1
        subscription.refreshPending = true
        if let deferredRefreshTask = subscription.deferredRefreshTask {
            return deferredRefreshTask
        }
        if let refreshTask = subscription.refreshTask {
            return refreshTask
        }
        let operationID = UUID()
        subscription.refreshOperationID = operationID
        let client = subscription.client
        let refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var refreshFailed = false
            var refreshShouldRetry = true
            var authorityReadFailedTransiently = false
            var completedPassCount = 0
            refreshLoop: repeat {
                guard !Task.isCancelled,
                      self.secondaryMacSubscriptions[ownerKey] === subscription
                else {
                    return
                }
                guard !subscription.isTransitioningToFocus else { break }
                completedPassCount += 1
                subscription.refreshPending = false
                let requestGeneration =
                    subscription.workspaceRefreshGeneration
                guard let scope = await self.currentScopeSnapshot() else {
                    refreshFailed = true
                    break
                }
                let attempt = await self.fetchSecondaryWorkspaces(
                    on: client,
                    macDeviceID: macID
                )
                guard !Task.isCancelled,
                      self.secondaryMacSubscriptions[ownerKey] === subscription
                else {
                    return
                }
                guard !subscription.isTransitioningToFocus else { break }
                switch await self.secondaryRefreshAuthorityRead(
                    macDeviceID: macID,
                    subscription: subscription,
                    scope: scope,
                    authorityValidation: authorityValidation
                ) {
                case .authorized:
                    break
                case .revoked:
                    refreshFailed = true
                    refreshShouldRetry = false
                    break refreshLoop
                case .transientFailure:
                    authorityReadFailedTransiently = true
                    break refreshLoop
                }
                let wasSuperseded =
                    subscription.workspaceRefreshGeneration
                    != requestGeneration
                let snapshot: SecondaryWorkspaceSnapshot
                switch attempt {
                case let .received(value):
                    // Publish every successful snapshot. Discarding a leading
                    // success lets sustained event churn starve the aggregate
                    // forever while requests keep completing.
                    snapshot = value
                case .transientFailure:
                    if wasSuperseded, completedPassCount < 2 {
                        continue refreshLoop
                    }
                    refreshFailed = true
                    break refreshLoop
                case .permanentFailure:
                    if wasSuperseded, completedPassCount < 2 {
                        continue refreshLoop
                    }
                    refreshFailed = true
                    refreshShouldRetry = false
                    break refreshLoop
                }
                self.workspacesByMac[ownerKey] = MacWorkspaceState(
                    macDeviceID: macID,
                    instanceTag: subscription.storedInstanceTag,
                    displayName: displayName ?? subscription.displayName,
                    workspaces: snapshot.workspaces,
                    groups: snapshot.groups
                        ?? self.workspacesByMac[ownerKey]?.groups
                        ?? [],
                    // A secondary list without group metadata keeps the last
                    // rows for continuity, but cannot authorize a restored
                    // destination until a fresh group snapshot arrives.
                    workspaceGroupsAreAuthoritative: snapshot.groups != nil,
                    status: .connected,
                    actionCapabilities: subscription.actionCapabilities
                )
                // One owner performs a leading pass plus at most one trailing
                // pass. The trailing host snapshot represents churn queued
                // during either request without creating an unbounded scan
                // train under a hot `workspace.updated` stream.
                if completedPassCount >= 2 {
                    break
                }
            } while subscription.refreshPending

            guard subscription.refreshOperationID == operationID else { return }
            let needsDeferredRefresh =
                subscription.refreshPending
                    && !refreshFailed
                    && !authorityReadFailedTransiently
            subscription.refreshTask = nil
            subscription.refreshOperationID = nil
            subscription.refreshPending = needsDeferredRefresh
            if needsDeferredRefresh {
                self.scheduleDeferredSecondaryWorkspaceRefresh(
                    subscription,
                    displayName: displayName,
                    authorityValidation: authorityValidation
                )
            }
            if authorityReadFailedTransiently {
                guard self.secondaryMacSubscriptions[ownerKey]
                        === subscription,
                      !subscription.isTransitioningToFocus else {
                    return
                }
                self.scheduleSecondaryAggregationRetry(
                    macDeviceIDs: [macID]
                )
                return
            }
            guard refreshFailed,
                  self.secondaryMacSubscriptions[ownerKey] === subscription,
                  !subscription.isTransitioningToFocus else {
                return
            }
            await self.retireSecondaryControlOwner(
                subscription,
                shouldRetry: refreshShouldRetry
            )
        }
        subscription.refreshTask = refreshTask
        return refreshTask
    }

    /// Preserve one edge that arrives during a trailing full-list fetch without
    /// immediately chaining another owner. Events during this short pause
    /// coalesce, limiting sustained churn to one leading/trailing pair per
    /// half-second while guaranteeing a post-edge snapshot.
    private func scheduleDeferredSecondaryWorkspaceRefresh(
        _ subscription: SecondaryMacSubscription,
        displayName: String?,
        authorityValidation: SecondaryStoredAuthorityValidation = .store
    ) {
        let ownerKey = subscription.ownerKey
        guard secondaryMacSubscriptions[ownerKey] === subscription,
              !subscription.isTransitioningToFocus,
              subscription.deferredRefreshTask == nil else {
            return
        }
        let operationID = UUID()
        let clock = controlPlaneSchedulingClock
        subscription.deferredRefreshOperationID = operationID
        subscription.deferredRefreshTask = Task { @MainActor [weak self] in
            defer {
                if subscription.deferredRefreshOperationID == operationID {
                    subscription.deferredRefreshTask = nil
                    subscription.deferredRefreshOperationID = nil
                }
            }
            do {
                try await clock.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  subscription.deferredRefreshOperationID == operationID,
                  self.secondaryMacSubscriptions[ownerKey]
                    === subscription,
                  !subscription.isTransitioningToFocus else {
                return
            }
            // Vacate the slot before enqueueing. Otherwise the refresh owner
            // would coalesce onto this already-running deferred task.
            subscription.deferredRefreshTask = nil
            subscription.deferredRefreshOperationID = nil
            subscription.refreshPending = false
            let refresh = self.enqueueSecondaryWorkspaceRefresh(
                subscription,
                displayName: displayName,
                authorityValidation: authorityValidation
            )
            await refresh?.value
        }
    }

    /// Coalesced full-list refresh for a secondary Mac driven by
    /// `workspace.updated` pushes. Leading + trailing: if a refresh is already
    /// running we only flag a trailing pass, so a hot event stream collapses to
    /// at most one extra scan after the in-flight one.
    private func scheduleSecondaryRefresh(
        ownerKey: MacPairingKey,
        client: MobileCoreRPCClient,
        displayName: String?
    ) {
        guard let subscription = secondaryMacSubscriptions[ownerKey],
              subscription.client === client else { return }
        enqueueSecondaryWorkspaceRefresh(
            subscription,
            displayName: displayName
        )
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
        let row = workspaces.first(where: { $0.id == id })
        let owner = row?.macDeviceID
        let isForegroundOwner = owner == nil
            || owner == Self.foregroundAnonymousKey
            || (owner == foregroundMacDeviceID
                && macInstanceTagAuthority.sameStoredAuthority(
                    row?.macInstanceTag, activeMacInstanceTag))
        if isForegroundOwner {
            return WorkspaceMutationTarget(
                client: remoteClient, isForeground: true, macDeviceID: foregroundMacDeviceID)
        }
        if let owner, let row {
            let ownerKey = MacPairingKey(
                macDeviceID: owner, instanceTag: row.macInstanceTag)
            if let sub = secondaryMacSubscriptions[ownerKey] {
                return WorkspaceMutationTarget(
                    client: sub.client, isForeground: false, macDeviceID: owner, ownerKey: ownerKey)
            }
        }
        return WorkspaceMutationTarget(client: nil, isForeground: false, macDeviceID: owner)
    }

    /// Re-sync the authoritative workspace list for the Mac a mutation actually hit:
    /// the foreground Mac's own list, or the owning secondary's coalesced re-fetch
    /// (so a pin/close on a secondary row snaps to the Mac's real state).
    public func refreshAfterWorkspaceMutation(id: MobileWorkspacePreview.ID) async {
        await refreshAfterWorkspaceMutation(workspaceMutationTarget(for: id))
    }

    func refreshAfterWorkspaceMutation(_ target: WorkspaceMutationTarget) async {
        if target.isForeground {
            await refreshForegroundWorkspaceListAfterMutation()
        } else if let ownerKey = target.ownerKey, let sub = secondaryMacSubscriptions[ownerKey] {
            scheduleSecondaryRefresh(
                ownerKey: ownerKey,
                client: sub.client,
                displayName: workspacesByMac[ownerKey]?.displayName)
        }
    }

    private func refreshForegroundWorkspaceListAfterMutation() async {
        guard connectionState == .connected, remoteClient != nil else { return }
        if let inFlight = foregroundWorkspaceMutationRefreshTask {
            foregroundWorkspaceMutationRefreshPending = true
            await inFlight.value
            return
        }
        let refreshGeneration = UUID()
        let refreshConnectionGeneration = connectionGeneration
        foregroundWorkspaceMutationRefreshGeneration = refreshGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            @MainActor func finishIfCurrent() {
                guard self.foregroundWorkspaceMutationRefreshGeneration == refreshGeneration else { return }
                self.foregroundWorkspaceMutationRefreshPending = false
                self.foregroundWorkspaceMutationRefreshTask = nil
            }
            repeat {
                guard self.foregroundWorkspaceMutationRefreshGeneration == refreshGeneration else { return }
                guard self.connectionGeneration == refreshConnectionGeneration,
                      !Task.isCancelled else {
                    finishIfCurrent()
                    return
                }
                self.foregroundWorkspaceMutationRefreshPending = false
                await self.reloadWorkspaceListFromMac()
                guard self.foregroundWorkspaceMutationRefreshGeneration == refreshGeneration else { return }
                guard self.connectionGeneration == refreshConnectionGeneration,
                      !Task.isCancelled else {
                    finishIfCurrent()
                    return
                }
            } while self.foregroundWorkspaceMutationRefreshPending
            finishIfCurrent()
        }
        foregroundWorkspaceMutationRefreshTask = task
        await task.value
    }

    /// Fire or reassert the server-side control subscription.
    @discardableResult
    private func enableSecondaryEventSubscription(
        on client: MobileCoreRPCClient,
        streamID: String
    ) async -> SecondaryEventSubscriptionActivation {
        guard let request = try? MobileCoreRPCClient.requestData(
            method: "mobile.events.subscribe",
            params: [
                "stream_id": streamID,
                "topics": Array(SecondaryMacSubscription.eventTopics).sorted(),
            ]
        ) else { return .permanentFailure }
        do {
            let responseData = try await client.sendRequest(
                request,
                timeoutNanoseconds: runtime?.livenessProbeTimeoutNanoseconds
            )
            guard let response = try? MobileEventSubscribeResponse.decode(
                      responseData
                  ),
                  response.streamID == streamID else {
                return .permanentFailure
            }
            return .active(requiresCatchUp: response.alreadySubscribed == false)
        } catch {
            return secondaryControlAttemptIsTransient(error)
                ? .transientFailure
                : .permanentFailure
        }
    }

    /// Cancel and disconnect every secondary subscription (sign-out / full reset),
    /// and cancel any in-flight aggregation pass so it cannot resume and re-seed
    /// the torn-down entries for a now-signed-out / switched account.
    private func teardownSecondaryMacSubscriptions() {
        cancelAllFocusTransitionMaintenance()
        secondaryAggregationTask?.cancel()
        secondaryAggregationTask = nil
        secondaryAggregationTaskGeneration = UUID()
        secondaryAggregationPending = false
        secondaryIrohDiscoveryPending = false
        secondaryPresenceAggregationTask?.cancel()
        secondaryPresenceAggregationTask = nil
        secondaryPresenceAggregationTaskGeneration = UUID()
        secondaryPresencePendingMacIDs = []
        for flight in secondaryMacEstablishmentFlights.values {
            flight.task.cancel()
        }
        secondaryAggregationAfterPushedRoutesOperationID = UUID()
        secondaryAggregationAfterPushedRoutesTask?.cancel()
        secondaryAggregationAfterPushedRoutesTask = nil
        secondaryAggregationAfterPushedRoutesScope = nil
        secondaryAggregationAfterPushedRoutesMacIDs = []
        secondaryAggregationAfterPushedRoutesNeedsFullRefresh = false
        cancelSecondaryAggregationRetry()
        secondaryControlKeepaliveTaskGeneration = UUID()
        secondaryControlKeepaliveTask?.cancel()
        secondaryControlKeepaliveTask = nil
        for task in secondaryControlReassertionTasksByOwnerKey.values {
            task.cancel()
        }
        secondaryControlReassertionTasksByOwnerKey = [:]
        secondaryControlReassertionTokensByOwnerKey = [:]
        secondaryControlReassertionOwnerIDsByOwnerKey = [:]
        for (_, subscription) in secondaryMacSubscriptions {
            if subscription.client === remoteClient {
                subscription.detachKeepingClient()
            } else {
                subscription.cancel()
            }
        }
        secondaryMacSubscriptions.removeAll()
        let drainReservations = Array(
            secondaryMacDrainReservations.values
        )
        secondaryMacDrainReservations.removeAll()
        for subscription in drainReservations {
            subscription.cancel()
        }
    }

    /// Whether the multi-Mac aggregated workspace list is enabled. Env override,
    /// then UserDefaults, then enabled by default. Env/defaults are kill switches
    /// for rollout control.
    var multiMacAggregationEnabled: Bool {
        MultiMacAggregationFlag(
            environment: ProcessInfo.processInfo.environment,
            defaults: multiMacAggregationDefaults
        ).isEnabled
    }

    /// Sentinel key for the foreground Mac when its attach ticket carries no
    /// macDeviceID (anonymous / manual host). Keeps the foreground entry in
    /// ``workspacesByMac`` addressable even without a real device id.
    static let foregroundAnonymousKey = "__cmux_foreground__"

    /// The key the foreground Mac's state lives under in ``workspacesByMac``:
    /// the exact foreground pairing (device id + active instance tag), or the
    /// anonymous sentinel before the host reports an identity.
    var foregroundMacKey: MacPairingKey {
        guard let foregroundMacDeviceID else { return .anonymousForeground }
        return MacPairingKey(
            macDeviceID: foregroundMacDeviceID,
            instanceTag: activeMacInstanceTag
        )
    }

    private func updateForegroundWorkspaceActionCapabilities() {
        guard var state = workspacesByMac[foregroundMacKey] else { return }
        state.actionCapabilities = Self.workspaceActionCapabilities(
            from: supportedHostCapabilities,
            allowsMacScopedMutations: allowsMacScopedWorkspaceMutations
        )
        workspacesByMac[foregroundMacKey] = state
    }

    /// Recompute the derived ``workspaces`` / ``workspaceGroups`` from the per-Mac
    /// source of truth. Pure and cheap; the only place those two are assigned,
    /// called on any ``workspacesByMac``, foreground, or sort-preference change.
    func recomputeDerivedWorkspaceState() {
        updateStableMacColorSlots()
        let previousTerminalNames = workspaces.reduce(into: [String: String]()) { names, workspace in
            for terminal in workspace.terminals {
                names[terminal.id.rawValue] = terminal.name
            }
        }
        let previousSelection = selectedWorkspaceID.flatMap { id in
            workspaces.first { $0.id == id }
        }
        let foregroundKey: String?
        if foregroundMacDeviceID != nil, workspacesByMac[foregroundMacKey] != nil {
            foregroundKey = foregroundMacKey.pairingID
        } else if workspacesByMac[.anonymousForeground] != nil {
            foregroundKey = Self.foregroundAnonymousKey
        } else {
            foregroundKey = nil
        }
        // The pure aggregation library speaks pairing-id strings; distinct
        // typed keys map to distinct pairing ids, so this conversion is
        // injective and the sentinel spelling is preserved.
        let statesByAggregateKey = Dictionary(
            uniqueKeysWithValues: workspacesByMac.map { ($0.key.pairingID, $0.value) }
        )
        // "Last Opened" recency for the automatic order, keyed by exact
        // pairing id. Stable and Nightly on one physical Mac keep independent
        // recency, while the live foreground check inside the aggregation still
        // beats either stored timestamp.
        var lastOpenedByPairingID: [String: Date] = [:]
        for mac in pairedMacs {
            let existing = lastOpenedByPairingID[mac.id]
            if existing == nil || mac.lastSeenAt > existing! {
                lastOpenedByPairingID[mac.id] = mac.lastSeenAt
            }
        }
        let macIDsInDisplayOrder = workspaceAggregation.orderedMacIDs(
            statesByMac: statesByAggregateKey,
            foregroundMacDeviceID: foregroundKey,
            computerPriority: workspaceSortMode == .computerPriority
                ? expandedWorkspaceComputerPriority()
                : [],
            lastOpenedAt: lastOpenedByPairingID
        )
        var derived = workspaceAggregation.derivedWorkspaces(
            statesByMac: statesByAggregateKey,
            foregroundMacDeviceID: foregroundKey,
            machineColorIndex: stableMacColorSlots,
            macIDsInDisplayOrder: macIDsInDisplayOrder
        )
        // Stamp per-Mac user color/icon overrides from pairedMacs so every
        // workspace avatar matches its computer's customization (same place the
        // aggregation already assigned the automatic color index).
        let customByMac = pairedMacCustomizationsByAliasID()
        if !customByMac.isEmpty {
            derived = derived.map { workspace in
                guard let macID = workspace.macDeviceID else { return workspace }
                let pairingID = MobilePairedMac.pairingID(
                    macDeviceID: macID,
                    instanceTag: workspace.macInstanceTag
                )
                guard let mac = customByMac[pairingID] else { return workspace }
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
        let terminalNames = derived.reduce(into: [String: String]()) { names, workspace in
            for terminal in workspace.terminals {
                names[terminal.id.rawValue] = terminal.name
            }
        }
        if terminalNames != previousTerminalNames {
            recordAppEvent(.surfaceListUpdated, count: terminalNames.count)
            for surfaceID in previousTerminalNames.keys where terminalNames[surfaceID] == nil {
                recordAppEvent(.terminalClosed, correlationID: surfaceID)
            }
            for (surfaceID, name) in terminalNames
            where previousTerminalNames[surfaceID].map({ $0 != name }) == true {
                recordAppEvent(.surfaceTitleChanged, correlationID: surfaceID)
            }
        }
        pruneTerminalThemes(to: derived)
        if let selectedWorkspaceID,
           !derived.contains(where: { $0.id == selectedWorkspaceID }) {
            let remapped = previousSelection.flatMap { previous in
                derived.first {
                    $0.rpcWorkspaceID == previous.rpcWorkspaceID
                        && MacPairingKey(
                            macDeviceID: $0.macDeviceID ?? "",
                            instanceTag: $0.macInstanceTag
                        ) == MacPairingKey(
                            macDeviceID: previous.macDeviceID ?? "",
                            instanceTag: previous.macInstanceTag
                        )
                }
            }
            self.selectedWorkspaceID = remapped?.id ?? derived.first?.id
        }
        if selectedWorkspaceID != nil { syncSelectedTerminalForWorkspace() }
        let derivedGroups = workspaceAggregation.derivedGroups(
            statesByMac: statesByAggregateKey,
            foregroundMacDeviceID: foregroundKey,
            macIDsInDisplayOrder: macIDsInDisplayOrder
        )
        workspaceGroups = groupCollapseStore.apply(to: derivedGroups)
    }

    /// Set the user's per-Mac customizations (name / color / icon), persist them
    /// locally, sync them to the per-user backup (so the user's other devices get
    /// them), and re-derive so the workspace avatars + Computers screen update.
    /// Empty strings are normalized to `nil` (cleared).
    public func updateMacCustomization(
        macDeviceID: String,
        instanceTag: String? = nil,
        customName: String?,
        customColor: String?,
        customIcon: String?
    ) async {
        let startedAt = appDiagnosticNow()
        func normalized(_ s: String?) -> String? {
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t?.isEmpty == false) ? t : nil
        }
        guard let scope = await currentScopeSnapshot() else {
            recordAppEvent(
                .computerAliasChanged,
                correlationID: MobilePairedMac.pairingID(
                    macDeviceID: macDeviceID,
                    instanceTag: instanceTag
                ),
                failure: .authorizationFailed
            )
            return
        }
        // The caller owns the complete pairing identity. Do not infer a build
        // tag from whichever same-device row happens to sort first, because a
        // Stable/Nightly sibling would otherwise receive the mutation.
        let targetInstanceTag = instanceTag
        let pairingID = MobilePairedMac.pairingID(
            macDeviceID: macDeviceID,
            instanceTag: targetInstanceTag
        )
        let name = normalized(customName), color = normalized(customColor), icon = normalized(customIcon), now = Date()
        guard let pairedMacStore else {
            recordAppEvent(
                .pairedMacStoreWriteFailed,
                correlationID: pairingID,
                startedAt: startedAt,
                failure: .unknown
            )
            return
        }
        do {
            try await pairedMacStore.setCustomization(
                macDeviceID: macDeviceID,
                instanceTag: targetInstanceTag,
                customName: name,
                customColor: color,
                customIcon: icon,
                stackUserID: scope.userID,
                teamID: scope.teamID,
                now: now
            )
            recordAppEvent(
                .computerAliasChanged,
                correlationID: pairingID,
                startedAt: startedAt,
                count: [name, color, icon].compactMap { $0 }.count
            )
            recordAppEvent(
                .pairedMacStoreWriteSucceeded,
                correlationID: pairingID,
                startedAt: startedAt
            )
        } catch {
            mobileShellLog.error("setCustomization failed pairing=\(pairingID, privacy: .private) error=\(String(describing: error), privacy: .private)")
            recordAppEvent(
                .computerAliasChanged,
                correlationID: pairingID,
                startedAt: startedAt,
                failure: DiagnosticFailureKind.classify(error)
            )
            recordAppEvent(
                .pairedMacStoreWriteFailed,
                correlationID: pairingID,
                startedAt: startedAt,
                failure: DiagnosticFailureKind.classify(error)
            )
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
            copy.macInstanceTag = activeMacInstanceTag
            return copy
        }
        var state = workspacesByMac[key] ?? MacWorkspaceState(
            macDeviceID: foregroundMacDeviceID ?? Self.foregroundAnonymousKey,
            instanceTag: key.normalizedInstanceTag
        )
        if foregroundMacDeviceID != nil {
            state.instanceTag = activeMacInstanceTag
        }
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
        if let groups {
            state.groups = groups
            state.workspaceGroupsAreAuthoritative = true
        } else if !merge {
            // A complete response without group metadata is not safe to use to
            // validate a restored group. Keep the rows, but require a future
            // authoritative group snapshot before clearing a pending ID.
            state.workspaceGroupsAreAuthoritative = false
        }
        state.status = .connected
        state.actionCapabilities = Self.workspaceActionCapabilities(
            from: supportedHostCapabilities,
            allowsMacScopedMutations: allowsMacScopedWorkspaceMutations
        )
        guard workspacesByMac[key] != state else { return }
        workspacesByMac[key] = state
    }

    #if DEBUG
    /// Replace the foreground Mac's workspaces/groups for DEBUG-only preview
    /// harnesses that exercise shell state without opening a live connection.
    public func replaceForegroundWorkspaceState(
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
        workspacesByMac = Dictionary(
            uniqueKeysWithValues: states.map { (MacPairingKey(pairingID: $0.key), $0.value) }
        )
    }

    /// Test seam for the secondary-refresh failure path: stale rows should stay
    /// visible but become unavailable when a secondary Mac cannot be reached.
    func markSecondaryMacUnavailableForTesting(_ macID: String) {
        markSecondaryMacUnavailable(MacPairingKey(pairingID: macID))
    }
    func foregroundMacDeviceIDForTesting() -> String? { foregroundMacDeviceID }

    func pooledRouteForTesting(macDeviceID: String) -> CmxAttachRoute? {
        connections[macDeviceID]?.route
    }
    func refreshRoutesFromRegistryForTesting(
        for mac: MobilePairedMac,
        scope: MobileShellScopeSnapshot
    ) {
        refreshRoutesFromRegistry(for: mac, scope: scope)
    }
    #endif

    func invalidateStoredMacReconnectAttempt() {
        storedMacReconnectGeneration &+= 1
        isReconnectingStoredMac = false
        pendingForcedStoredMacReconnect = false
    }

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
    func dropStalePreviousForeground(_ previousKey: MacPairingKey) {
        guard previousKey != foregroundMacKey,
              secondaryMacSubscriptions[previousKey] == nil else { return }
        workspacesByMac[previousKey] = nil
    }

    /// Adopt a host-reported real device id as the foreground Mac's aggregate key.
    /// A compact/anonymous QR ticket connects with an empty `macDeviceID`, so the
    /// foreground state lands under the anonymous key with `foregroundMacDeviceID`
    /// nil. When `mobile.host.status` later reports the real id, move that state to
    /// the real id and stamp its rows — otherwise the Computers screen shows the
    /// connected Mac as "not connected" (foregroundMacDeviceID never matched) and
    /// secondary aggregation, which excludes `foregroundMacDeviceID`, can open a
    /// DUPLICATE read-only connection to the very Mac that is already foreground.
    private func adoptForegroundMacIdentity(
        _ macDeviceID: String,
        previousKey: MacPairingKey? = nil
    ) {
        guard !macDeviceID.isEmpty else { return }
        // `activeMacInstanceTag` may have been adopted just before this call,
        // so the caller passes the key the state was written under; falling
        // back to the current key covers pure device-id adoption.
        let oldKey = previousKey ?? foregroundMacKey
        foregroundMacDeviceID = macDeviceID
        let newKey = foregroundMacKey
        guard oldKey != newKey else { return }
        if var state = workspacesByMac[oldKey] {
            workspacesByMac[oldKey] = nil
            state.macDeviceID = macDeviceID
            state.instanceTag = newKey.normalizedInstanceTag
            state.workspaces = state.workspaces.map { workspace in
                var copy = workspace
                copy.macDeviceID = macDeviceID
                copy.macInstanceTag = newKey.normalizedInstanceTag
                return copy
            }
            // Don't clobber a (somehow) pre-existing real-id entry; merge by keeping
            // the live foreground rows.
            workspacesByMac[newKey] = state
        }
        if let connection = connections[oldKey.canonicalMacDeviceID] {
            removeFocusedConnection(ifMatching: connection)
            installFocusedConnection(MacConnection(
                macDeviceID: macDeviceID,
                ticket: activeTicket ?? connection.ticket,
                route: connection.route,
                client: connection.client,
                generation: connection.generation,
                displayName: connectedHostName,
                storedInstanceTag: connection.storedInstanceTag,
                authenticatedInstanceTag:
                    activeMacInstanceTag
                        ?? connection.authenticatedInstanceTag,
                supportedHostCapabilities: supportedHostCapabilities,
                actionCapabilities: Self.workspaceActionCapabilities(
                    from: supportedHostCapabilities,
                    allowsMacScopedMutations: allowsMacScopedWorkspaceMutations
                )
            ))
        } else if let client = remoteClient,
                  let ticket = activeTicket,
                  let route = activeRoute {
            // Anonymous connections have no registry key at initial auth time.
            // Once status supplies the real id, register the already-live client
            // so a later Mac switch can demote it into the warm control pool.
            installFocusedConnection(MacConnection(
                macDeviceID: macDeviceID,
                ticket: ticket,
                route: route,
                client: client,
                generation: connectionGeneration,
                displayName: connectedHostName,
                instanceTag: activeMacInstanceTag,
                supportedHostCapabilities: supportedHostCapabilities,
                actionCapabilities: Self.workspaceActionCapabilities(
                    from: supportedHostCapabilities,
                    allowsMacScopedMutations: allowsMacScopedWorkspaceMutations
                )
            ))
        }
    }

    /// Apply an optimistic mutation to the foreground Mac's workspace list (e.g. a
    /// just-created workspace or terminal) directly on the per-Mac source of
    /// truth, so the derived list reflects it immediately.
    func mutateForegroundWorkspaces(_ body: (inout [MobileWorkspacePreview]) -> Void) {
        let key = foregroundMacKey
        var state = workspacesByMac[key] ?? MacWorkspaceState(
            macDeviceID: foregroundMacDeviceID ?? Self.foregroundAnonymousKey,
            instanceTag: key.normalizedInstanceTag
        )
        body(&state.workspaces)
        workspacesByMac[key] = state
    }
    /// Create a workspace locally or through the connected Mac, then select it.
    public func createWorkspace(
        inGroup groupID: MobileWorkspaceGroupPreview.ID? = nil
    ) {
        guard remoteClient == nil else {
            guard createWorkspaceTask == nil else { return }
            let taskID = UUID()
            createWorkspaceTaskID = taskID
            createWorkspaceTask = Task { @MainActor [weak self] in
                defer { self?.clearCreateWorkspaceTask(id: taskID) }
                guard let self else { return .success(()) }
                return await self.createRemoteWorkspace(inGroup: groupID)
            }
            createWorkspaceTaskGroupID = groupID
            createWorkspaceTaskSpec = nil
            return
        }
        guard groupID == nil else { return }
        if createLocalWorkspaceWithoutTerminalForDelayedUITestIfNeeded() { return }
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
            guard createTerminalTask == nil else {
                recordAppEvent(
                    .terminalCreateFailed,
                    correlationID: targetWorkspaceID?.rawValue,
                    failure: .routeGated
                )
                return
            }
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
            recordAppEvent(
                .terminalCreateFailed,
                correlationID: targetWorkspaceID?.rawValue,
                failure: .endpointUnavailable
            )
            return
        }
        recordAppEvent(
            .terminalCreateStarted,
            correlationID: targetWorkspaceID?.rawValue
        )
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
        recordAppEvent(
            .terminalCreateSucceeded,
            correlationID: terminal.id.rawValue
        )
    }

    /// Select the active terminal by id without changing workspace selection.
    public func selectTerminal(_ id: MobileTerminalPreview.ID?) {
        guard selectedTerminalID != id else { return }
        selectedTerminalID = id
        if let id {
            recordAppEvent(
                .surfaceSelected,
                correlationID: id.rawValue
            )
        }
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
        guard selectedTerminalID != id else { return }
        selectedTerminalID = id
        recordAppEvent(
            .surfaceSelected,
            correlationID: id.rawValue
        )
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
    func suppressTerminalAutoFocusOnNextAttach(for terminalID: MobileTerminalPreview.ID?) {
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
        guard reportedViewportSizesByTerminalKey[key] != viewportSize else { return }
        reportedViewportSizesByTerminalKey[key] = viewportSize
        recordAppEvent(
            .terminalViewportChanged,
            correlationID: terminalID.rawValue,
            count: viewportSize.columns * viewportSize.rows
        )
    }

    /// Open the workspace preview, switching the foreground Mac first when the workspace belongs to another paired Mac.
    public func openWorkspace(_ id: MobileWorkspacePreview.ID) async {
        let diagnosticStartedAt = appDiagnosticNow()
        recordAppEvent(
            .workspaceOpenStarted,
            correlationID: id.rawValue
        )
        let workspace = workspaces.first { $0.id == id }
        let remoteWorkspaceID = workspace?.rpcWorkspaceID ?? id
        let ownerMacDeviceID = workspace?.macDeviceID
        let ownerInstanceTag = workspace?.macInstanceTag
        let workspaceHadUnread = workspace?.hasUnread == true
        // Cross-Mac open (P5): a workspace from the aggregated list may belong
        // to a Mac — or a sibling BUILD of the foreground's own Mac — other
        // than the current foreground connection. Switch the foreground to
        // that exact pairing first so the terminal attaches to the right one.
        // No nil-tag wildcard: an untagged row on the foreground DEVICE may
        // belong to a legacy sibling pairing, and treating it as
        // foreground-owned would route its open through a tagged build's
        // client. `sameStoredAuthority(nil, nil)` still matches the ordinary
        // untagged-foreground case.
        let rowIsForegroundPairing = ownerMacDeviceID == foregroundMacDeviceID
            && macInstanceTagAuthority.sameStoredAuthority(
                ownerInstanceTag,
                activeMacInstanceTag
            )
        if multiMacAggregationEnabled,
           let macDeviceID = ownerMacDeviceID,
           !macDeviceID.isEmpty,
           !rowIsForegroundPairing {
            // Only proceed if that Mac actually became the foreground connection.
            // The tap already selected this workspace and pushed its detail
            // synchronously (this runs from the detail's task), so on a failed
            // switch ROLL BACK the selection — popping the compact stack back to the
            // list — instead of leaving the user in a workspace whose Mac is not the
            // live connection (terminal input would route to the wrong client). The
            // offline row's Reconnect / the next aggregation pass recovers it.
            guard await switchToMac(
                macDeviceID: macDeviceID,
                instanceTag: ownerInstanceTag
            ) else {
                mobileShellLog.error("openWorkspace: switch to mac failed, popping mac=\(macDeviceID, privacy: .public)")
                recordAppEvent(
                    .workspaceOpenFailed,
                    correlationID: id.rawValue,
                    startedAt: diagnosticStartedAt,
                    failure: .connectionClosed
                )
                if selectedWorkspaceID == id {
                    setSelectedWorkspaceID(nil)
                }
                return
            }
        }
        let resolvedRowID = rowWorkspaceID(
            forRemoteWorkspaceID: remoteWorkspaceID,
            macDeviceID: ownerMacDeviceID,
            instanceTag: ownerInstanceTag
        ) ?? (workspaces.contains(where: { $0.id == id }) ? id : nil)
        guard let resolvedRowID else {
            mobileShellLog.error("openWorkspace: workspace disappeared after switch id=\(remoteWorkspaceID.rawValue, privacy: .private) mac=\(ownerMacDeviceID ?? "", privacy: .public)")
            recordAppEvent(
                .workspaceOpenFailed,
                correlationID: id.rawValue,
                startedAt: diagnosticStartedAt,
                failure: .superseded
            )
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
        recordAppEvent(
            .workspaceOpenSucceeded,
            correlationID: resolvedRowID.rawValue,
            startedAt: diagnosticStartedAt,
            count: workspace?.terminals.count
        )
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
        let terminalID = selectedTerminalID?.rawValue
        recordAppEvent(
            .terminalInputSubmitted,
            correlationID: terminalID,
            count: text.utf8.count
        )
        terminalInputText = ""
        guard remoteClient != nil else {
            recordAppEvent(
                .terminalInputDropped,
                correlationID: terminalID,
                failure: .offline
            )
            return
        }
        // North-star event. One per submit, never per keystroke. Sizes/counts
        // only — never the text itself (the call below ships the text; analytics
        // ships only its byte and line counts, mirroring the code's own
        // `byteCount` privacy:.public logging posture).
        analytics.capture("ios_terminal_input_submitted", [
            "byte_count": .int(text.utf8.count),
            "line_count": .int(text.split(separator: "\n", omittingEmptySubsequences: false).count),
            "had_attachment": .bool(false),
        ])
        await submitTerminalRawInput(text + "\r")
        recordAppEvent(
            .terminalInputSent,
            correlationID: terminalID
        )
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
    /// set): both explicit transitions land here so diagnostics record every
    /// flag change, exactly like the old stored property's `didSet`. A
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
        // The state and process-local surface handle are safe to persist in
        // Release and explain whether a missing band was intentionally closed.
        diagnosticLog?.record(DiagnosticEvent(
            .composerPresentedChanged,
            surface: Self.diagnosticSurfaceHandle(terminalID),
            a: presented ? 1 : 0
        ))
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
    public func addPendingAttachment(
        _ data: Data,
        format: String,
        thumbnailData: Data? = nil,
        forTerminalID terminalID: String? = nil
    ) -> MobilePendingAttachment.ID? {
        stagePendingAttachment(
            kind: .image,
            data: data,
            format: format,
            displayName: nil,
            thumbnailData: thumbnailData,
            forTerminalID: terminalID
        )
    }

    /// Stage arbitrary file bytes as a pending attachment for a terminal. The
    /// bytes are uploaded to the Mac at send time (through the chunked
    /// task-attachment verb) and the message references the returned path,
    /// shell-quoted, ahead of the user's text.
    /// - Parameters:
    ///   - data: The raw file bytes, already under the per-file cap.
    ///   - fileExtension: A lowercase extension hint for the chip and upload.
    ///   - displayName: The user-visible file name, sent as the upload name.
    ///   - terminalID: The terminal to stage under; `nil` falls back to the
    ///     selected terminal.
    /// - Returns: The new attachment's stable id, or `nil` when nothing was
    ///   staged (see ``addPendingAttachment(_:format:forTerminalID:)``).
    @discardableResult
    public func addPendingFileAttachment(
        _ data: Data,
        fileExtension: String,
        displayName: String,
        thumbnailData: Data? = nil,
        forTerminalID terminalID: String? = nil
    ) -> MobilePendingAttachment.ID? {
        stagePendingAttachment(
            kind: .file,
            data: data,
            format: fileExtension,
            displayName: displayName,
            thumbnailData: thumbnailData,
            forTerminalID: terminalID
        )
    }

    /// Stage file bytes only if the captured session token still matches and
    /// (when explicit) the target terminal still exists — the same stale-result
    /// guard as the image variant, for the paste path whose materialization and
    /// disk reads await off-main.
    @discardableResult
    public func addPendingFileAttachment(
        _ data: Data,
        fileExtension: String,
        displayName: String,
        thumbnailData: Data? = nil,
        forTerminalID terminalID: String? = nil,
        ifSessionGeneration capturedGeneration: Int
    ) -> MobilePendingAttachment.ID? {
        guard capturedGeneration == signInGeneration else {
            recordAppEvent(
                .terminalAttachmentRejected,
                correlationID: terminalID,
                failure: .superseded
            )
            return nil
        }
        if let terminalID, !terminalExistsInTopology(terminalID) {
            recordAppEvent(
                .terminalAttachmentRejected,
                correlationID: terminalID,
                failure: .superseded
            )
            return nil
        }
        return addPendingFileAttachment(
            data,
            fileExtension: fileExtension,
            displayName: displayName,
            thumbnailData: thumbnailData,
            forTerminalID: terminalID
        )
    }

    /// The single validated staging path: every image and file add (plain or
    /// session-guarded) funnels through here so the per-kind size cap, the
    /// per-terminal count/byte budgets, and the global all-terminals budgets
    /// are enforced atomically against the CURRENT staged set on the main
    /// actor.
    private func stagePendingAttachment(
        kind: MobilePendingAttachment.Kind,
        data: Data,
        format: String,
        displayName: String?,
        thumbnailData: Data?,
        forTerminalID terminalID: String?
    ) -> MobilePendingAttachment.ID? {
        let key = terminalID ?? selectedTerminalID?.rawValue
        func reject(
            _ failure: DiagnosticFailureKind,
            count: Int? = nil
        ) -> MobilePendingAttachment.ID? {
            recordAppEvent(
                .terminalAttachmentRejected,
                correlationID: key,
                failure: failure,
                count: count
            )
            return nil
        }
        guard !data.isEmpty else { return reject(.protocolViolation) }
        guard let key else { return reject(.noRoute) }
        // Reject any add for a terminal that is not in the current topology, so a
        // closed/recreated/stale id can never accrue orphaned bytes the user can no
        // longer see or send.
        guard terminalExistsInTopology(key) else { return reject(.superseded) }
        // A single item larger than its kind's cap is rejected outright: images
        // are bounded by the encode target, files by the send-time upload limit.
        let perItemCap = switch kind {
        case .image: Self.maxPendingAttachmentImageBytes
        case .file: Self.maxPendingAttachmentFileBytes
        }
        guard data.count <= perItemCap else {
            return reject(.payloadTooLarge, count: data.count)
        }
        let existing = pendingAttachmentsByTerminalID[key] ?? []
        // Count cap, computed against the CURRENT staged set (atomic on @MainActor).
        guard existing.count < Self.maxPendingAttachmentCount else {
            return reject(.resourceLimitReached, count: existing.count)
        }
        // Total-byte budget, likewise against the current set.
        let currentBytes = existing.reduce(0) { $0 + $1.data.count }
        guard currentBytes + data.count <= Self.maxPendingAttachmentTotalBytes else {
            return reject(.resourceLimitReached, count: currentBytes + data.count)
        }
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
        guard globalCount < Self.maxPendingAttachmentCountAllTerminals else {
            return reject(.resourceLimitReached, count: globalCount)
        }
        guard globalBytes + data.count <= Self.maxPendingAttachmentTotalBytesAllTerminals else {
            return reject(.resourceLimitReached, count: globalBytes + data.count)
        }
        let attachment = MobilePendingAttachment(
            kind: kind,
            data: data,
            format: format,
            displayName: displayName,
            thumbnailData: thumbnailData
        )
        pendingAttachmentsByTerminalID[key, default: []].append(attachment)
        recordAppEvent(
            .terminalAttachmentStaged,
            correlationID: key,
            count: data.count
        )
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
        thumbnailData: Data? = nil,
        forTerminalID terminalID: String? = nil,
        ifSessionGeneration capturedGeneration: Int
    ) -> MobilePendingAttachment.ID? {
        // A sign-out (or account switch) bumped the token while the photo was
        // loading/encoding: this is the previous user's content, drop it.
        guard capturedGeneration == signInGeneration else {
            recordAppEvent(
                .terminalAttachmentRejected,
                correlationID: terminalID,
                failure: .superseded
            )
            return nil
        }
        // For an explicit target, require it to still exist so a closed terminal
        // does not accrue orphaned bytes the user can no longer see or send. The
        // base add re-validates this for every path (including the selected-id
        // fallback), so existence is enforced once and only once below.
        if let terminalID, !terminalExistsInTopology(terminalID) {
            recordAppEvent(
                .terminalAttachmentRejected,
                correlationID: terminalID,
                failure: .superseded
            )
            return nil
        }
        return addPendingAttachment(
            data,
            format: format,
            thumbnailData: thumbnailData,
            forTerminalID: terminalID
        )
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
        for (terminalID, attachments) in pendingAttachmentsByTerminalID
        where !liveTerminalIDs.contains(terminalID) {
            recordAppEvent(
                .terminalAttachmentRemoved,
                correlationID: terminalID,
                failure: .superseded,
                count: attachments.count
            )
        }
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
        let previousCount = list.count
        list.removeAll { $0.id == id }
        guard list.count != previousCount else { return }
        if list.isEmpty {
            pendingAttachmentsByTerminalID[key] = nil
        } else {
            pendingAttachmentsByTerminalID[key] = list
        }
        recordAppEvent(
            .terminalAttachmentRemoved,
            correlationID: key,
            count: list.count
        )
    }

    /// Drop every staged attachment for a terminal (used after a successful send).
    /// - Parameter terminalID: The terminal to clear; `nil` falls back to the
    ///   selected terminal.
    public func clearPendingAttachments(forTerminalID terminalID: String? = nil) {
        guard let key = terminalID ?? selectedTerminalID?.rawValue,
              let removedCount = pendingAttachmentsByTerminalID[key]?.count,
              removedCount > 0 else { return }
        pendingAttachmentsByTerminalID[key] = nil
        recordAppEvent(
            .terminalAttachmentRemoved,
            correlationID: key,
            count: removedCount
        )
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
    @discardableResult
    public func submitComposerInput() async -> Bool {
        guard let workspaceID = selectedWorkspace?.id,
              let terminalID = selectedTerminalID else { return false }
        return await submitComposerInput(
            workspaceID: workspaceID,
            terminalID: terminalID
        )
    }

    /// Submit the composer's text to an explicitly captured terminal. Used by
    /// ``submitComposer()`` so a terminal switch mid-send cannot reroute the text
    /// to whatever is selected when the (awaited) image sends return: the target
    /// is captured once up front and threaded through here, while the draft
    /// reconciliation still keys on that captured terminal (not the live
    /// selection).
    ///
    /// - Parameters:
    ///   - capturedText: The exact text to send, snapshotted by the
    ///     caller before any await. When `nil`, the live ``terminalInputText`` is
    ///     read (the text-only entry points have no earlier await, so there is no
    ///     snapshot to drift). ``submitComposer()`` MUST pass a snapshot: a terminal
    ///     switch or a field edit during its attachment awaits would otherwise make
    ///     this send (and the draft reconcile) read a different terminal's draft or
    ///     skip the text the user actually composed at Send time.
    ///   - draftTextToReconcile: What the FIELD held at Send time, when it
    ///     differs from the sent text. ``submitComposer()`` prepends uploaded
    ///     file paths to the sent text, so the post-ack draft clear must compare
    ///     the field against the un-prepended snapshot or it would never match
    ///     and the sent draft would resurrect. `nil` means the sent text IS the
    ///     field text.
    ///
    /// - Returns: `true` when the Mac acknowledged the paste (or the text was
    ///   empty, i.e. nothing to send), `false` when the send failed so the caller
    ///   keeps the text for a retry.
    @discardableResult
    func submitComposerInput(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID,
        capturedText: String? = nil,
        draftTextToReconcile: String? = nil
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
        // when the ack returns. A files-only send has an empty field snapshot,
        // so there is no draft to clear.
        let draftText = draftTextToReconcile ?? text
        if !draftText.isEmpty {
            await reconcileComposerDraftAfterSend(
                sentText: draftText,
                submittedTerminalID: terminalID
            )
        }
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
    @discardableResult
    public func submitComposer() async -> Bool {
        // Reject a re-entrant submit (e.g. a double tap on Send): the button
        // stays enabled while the first image RPC awaits, and a second submit
        // would capture the same still-staged attachments and re-upload them.
        // Set/cleared on the main actor around the awaits, so no second call can
        // slip past. A failed send keeps the attachments staged (below), so the
        // user can retry once this flag clears.
        guard !isSubmittingComposer else { return false }
        isSubmittingComposer = true
        defer { isSubmittingComposer = false }
        guard let workspaceID = selectedWorkspace?.id,
              let submittedTerminalID = selectedTerminalID else {
            // No target: fall back to the text-only path, which is itself a no-op
            // without a selected terminal.
            return await submitComposerInput()
        }
        let sendOperationID = beginTerminalSend(
            forTerminalID: submittedTerminalID.rawValue
        )
        var sendSucceeded = false
        defer {
            finishTerminalSend(
                sendOperationID,
                forTerminalID: submittedTerminalID.rawValue,
                succeeded: sendSucceeded
            )
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
        let submitClient = remoteClient
        // Deliver each attachment first and await it, so the agent's terminal has
        // the file paths before the text arrives. Images travel inline through
        // `terminal.paste_image` and are removed per-ack; files are uploaded
        // through the chunked task-attachment verb and their returned Mac paths
        // are prepended (shell-quoted) to the text below. On failure stop and
        // keep the rest (and the text) staged.
        var uploadedFilePaths: [(id: MobilePendingAttachment.ID, path: String)] = []
        for attachment in attachments {
            // Re-check the captured session/connection still matches before each
            // attachment send (the previous iteration's send was awaited). A
            // mismatch means the session or transport was replaced mid-submit;
            // abort without sending so nothing leaks into the new session.
            // Attachments are left staged (no removal happened for this
            // iteration).
            guard isComposerSubmitIdentityCurrent(
                signIn: submitSignInGeneration,
                connection: submitConnectionGeneration,
                client: submitClient
            ) else { return false }
            // Re-check the attachment is still staged for the captured terminal
            // before uploading it. The user can delete a not-yet-acked chip while
            // an earlier attachment's send is in flight; that removes it from
            // `pendingAttachmentsByTerminalID`, but this loop iterates a snapshot
            // taken before the awaits. Skipping the removed one keeps the local
            // snapshot from re-uploading bytes the user already dismissed. Runs on
            // the @MainActor, so the membership check is consistent with the
            // removal.
            guard pendingAttachments(forTerminalID: submittedTerminalID.rawValue)
                .contains(where: { $0.id == attachment.id }) else { continue }
            switch attachment.kind {
            case .image:
                let sent = await submitTerminalPasteImage(
                    attachment.data,
                    format: attachment.format,
                    workspaceID: workspaceID,
                    terminalID: submittedTerminalID
                )
                guard sent else { return false }
                removePendingAttachment(id: attachment.id, forTerminalID: submittedTerminalID.rawValue)
            case .file:
                guard case .success(let path) =
                        await uploadPendingFileAttachment(attachment) else {
                    return false
                }
                // NOT removed yet: the path is only useful once the text send
                // that references it acks. Removing now would strand the file if
                // that send fails; keeping it staged means a retry re-uploads (a
                // fresh path on whatever Mac is then current) instead of silently
                // dropping the attachment.
                uploadedFilePaths.append((id: attachment.id, path: path))
            }
        }
        // Re-check the captured identity one last time before the text send. The
        // final attachment's send was awaited above, so a sign-out / Mac switch /
        // reconnect could have landed after it; abort (keep the text staged in the
        // field) rather than paste the user's message into the now-current
        // session.
        guard isComposerSubmitIdentityCurrent(
            signIn: submitSignInGeneration,
            connection: submitConnectionGeneration,
            client: submitClient
        ) else { return false }
        // Prepend each uploaded file's quoted Mac path BEFORE the user's message
        // (an agent reads the references, then the message about them). The
        // field itself never contained the paths, so the draft reconcile below
        // compares against the field snapshot, not the composed text.
        var composedText = ""
        for (_, path) in uploadedFilePaths {
            composedText = TerminalComposerAttachmentInsertion(path: path)
                .appending(to: composedText)
        }
        composedText += submittedText
        // Submit the composed text to the captured terminal (a no-op when empty,
        // e.g. an images-only send; a files-only send is non-empty because of
        // the prepended paths). All attachments acked by here, so the text
        // follows. Passing the snapshot (not the live field) keeps this immune to
        // a switch/edit that happened during the attachment awaits above.
        sendSucceeded = await submitComposerInput(
            workspaceID: workspaceID,
            terminalID: submittedTerminalID,
            capturedText: composedText,
            draftTextToReconcile: submittedText
        )
        if sendSucceeded {
            // The text referencing the uploaded paths is acked; the file chips
            // are now delivered and can leave the staged set.
            for (id, _) in uploadedFilePaths {
                removePendingAttachment(id: id, forTerminalID: submittedTerminalID.rawValue)
            }
        }
        return sendSucceeded
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
    func isComposerSubmitIdentityCurrent(
        signIn: Int,
        connection: UUID,
        client: MobileCoreRPCClient? = nil
    ) -> Bool {
        signIn == signInGeneration
            && connection == connectionGeneration
            && (client == nil || remoteClient === client)
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
        let sendStatusOperationID = prepareTerminalSendStatusForRawInput(
            text,
            terminalID: terminalID.rawValue
        )
        let enqueueResult = rawTerminalInputBuffer.enqueue(
            text,
            workspaceID: workspaceID,
            terminalID: terminalID,
            sendStatusOperationID: sendStatusOperationID
        )
        if enqueueResult == .rejected {
            finishRawTerminalSend(
                sendStatusOperationID,
                forTerminalID: terminalID.rawValue,
                succeeded: false
            )
        }
        handleSynchronousRawTerminalInputEnqueueResult(enqueueResult)
    }

    /// Enqueue raw UTF-8 input for the terminal identified by `surfaceID`.
    public func sendTerminalRawInput(_ data: Data, surfaceID: String) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return
        }
        guard let workspaceID = workspaceID(forTerminalID: surfaceID) else { return }
        let sendStatusOperationID = prepareTerminalSendStatusForRawInput(
            text,
            terminalID: surfaceID
        )
        let enqueueResult = rawTerminalInputBuffer.enqueue(
            text,
            workspaceID: workspaceID,
            terminalID: MobileTerminalPreview.ID(rawValue: surfaceID),
            sendStatusOperationID: sendStatusOperationID
        )
        if enqueueResult == .rejected {
            finishRawTerminalSend(
                sendStatusOperationID,
                forTerminalID: surfaceID,
                succeeded: false
            )
        }
        handleSynchronousRawTerminalInputEnqueueResult(enqueueResult)
    }

    private func handleSynchronousRawTerminalInputEnqueueResult(
        _ enqueueResult: MobileTerminalInputEnqueueResult
    ) {
        switch enqueueResult {
        case .startDraining:
            Task { @MainActor [weak self] in
                await self?.drainRawTerminalInputBuffer()
            }
        case .queued:
            return
        case .rejected:
            handleRawTerminalInputOverflow()
        }
    }

    private func prepareTerminalSendStatusForRawInput(
        _ text: String,
        terminalID: String
    ) -> UUID? {
        if Self.containsTerminalSubmission(text) {
            let operationID = beginTerminalSend(
                forTerminalID: terminalID
            )
            rawTerminalSendOperationIDsByTerminalID[terminalID] = operationID
            return operationID
        } else {
            clearSettledTerminalSendStatus(forTerminalID: terminalID)
            return nil
        }
    }

    private nonisolated static func containsTerminalSubmission(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.value == 0x0D || scalar.value == 0x0A
        }
    }

    /// Submit raw text to the currently selected terminal when one is available.
    public func submitTerminalRawInput(_ text: String) async {
        guard !text.isEmpty else { return }
        guard let workspaceID = selectedWorkspace?.id,
              let terminalID = selectedTerminalID else {
            return
        }
        await enqueueTerminalRawInputAwaitingDrain(
            text,
            workspaceID: workspaceID,
            terminalID: terminalID
        )
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
        guard let workspaceID = workspaceID(forTerminalID: surfaceID) else { return }
        await enqueueTerminalRawInputAwaitingDrain(
            text,
            workspaceID: workspaceID,
            terminalID: MobileTerminalPreview.ID(rawValue: surfaceID)
        )
    }

    private func enqueueTerminalRawInputAwaitingDrain(
        _ text: String,
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) async {
        guard !text.isEmpty else { return }
        guard remoteClient != nil else { return }
        switch rawTerminalInputBuffer.enqueue(
            text,
            workspaceID: workspaceID,
            terminalID: terminalID
        ) {
        case .startDraining:
            await drainRawTerminalInputBuffer()
            // A stale drain loop may still own the buffer (the runner guard
            // made our call a no-op); wait for it so awaited submitters only
            // return once their input has actually been handed to the sender.
            await awaitRawTerminalInputDrainCompletion()
        case .queued:
            await awaitRawTerminalInputDrainCompletion()
        case .rejected:
            handleRawTerminalInputOverflow()
        }
    }

    private func drainRawTerminalInputBuffer() async {
        // A drain Task can outlive rawTerminalInputBuffer.clear(): the buffer's
        // isDraining flag resets synchronously, so a new enqueue can start a
        // second loop while the old one is still awaiting a send. Two loops
        // interleaving sends is exactly the input reorder this pipeline exists
        // to prevent, so an instance-level runner flag keeps at most one loop
        // alive; late starters return and the active loop drains their chunks.
        guard !isRawTerminalInputDrainLoopRunning else { return }
        isRawTerminalInputDrainLoopRunning = true
        defer {
            isRawTerminalInputDrainLoopRunning = false
            resumeRawTerminalInputDrainWaiters()
        }
        // Matches MobileIrohTerminalLane.maximumInputByteCount and the Mac lane
        // router's maximumInputFrameByteCount.
        while let chunk = rawTerminalInputBuffer.nextBatch(maximumByteCount: 16 * 1_024) {
            #if DEBUG
            rawTerminalInputLatencyBatchNumber &+= 1
            let latencyBatchNumber = rawTerminalInputLatencyBatchNumber
            MobileLatencyTrace.stamp(
                "in.send",
                "n=\(latencyBatchNumber) bytes=\(chunk.text.utf8.count)"
            )
            let latencyBatchNumberForSend: UInt64? = latencyBatchNumber
            #else
            let latencyBatchNumberForSend: UInt64? = nil
            #endif
            await sendRemoteTerminalInput(
                chunk.text,
                workspaceID: chunk.workspaceID,
                terminalID: chunk.terminalID,
                latencyBatchNumber: latencyBatchNumberForSend,
                sendStatusOperationID: chunk.sendStatusOperationID
            )
        }
    }

    private func awaitRawTerminalInputDrainCompletion() async {
        guard rawTerminalInputBuffer.isDraining else { return }
        await withCheckedContinuation { continuation in
            rawTerminalInputDrainWaiters.append(continuation)
        }
    }

    func clearPendingTerminalInputForFocusChange() {
        rawTerminalInputBuffer.clear()
        terminalInputRPCPipeline.clear()
        let pendingRawSends = rawTerminalSendOperationIDsByTerminalID
        for (terminalID, operationID) in pendingRawSends {
            finishRawTerminalSend(
                operationID,
                forTerminalID: terminalID,
                succeeded: false
            )
        }
        resumeRawTerminalInputDrainWaiters()
    }

    private func resumeRawTerminalInputDrainWaiters() {
        let waiters = rawTerminalInputDrainWaiters
        rawTerminalInputDrainWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func handleRawTerminalInputOverflow() {
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

    /// Establishes the live connection for `ticket`. Returns `nil` on success
    /// (and superseded-generation early exits), or the failure category it applied
    /// when it returned without connecting and without throwing
    /// (`.noSupportedRoute`), so callers record the matching analytics reason.
    @discardableResult
    func connect(
        ticket: CmxAttachTicket,
        allowsStackAuthFallback: Bool? = nil,
        legacyTailscaleRoutes: [CmxAttachRoute] = [],
        userTailscalePairingAuthorizations: [CmxUserTailscalePairingAuthorization] = [],
        directOnlyDialCandidates: [CmxIrohDirectDialCandidate]? = nil,
        pairedMacDeviceID: String? = nil,
        instanceTagExpectation: MobileMacInstanceTagExpectation = .adopt,
        ifStillCurrent: (() -> Bool)? = nil
    ) async throws -> MobilePairingFailureCategory? {
        // A bounded reconnect can outlive its owning task when an FFI dial
        // ignores cancellation. Its authority closure must be checked before
        // claiming the foreground generation or clearing the established
        // client, otherwise the abandoned attempt briefly disconnects the
        // newer session even though every later adoption guard rejects it.
        guard ifStillCurrent?() ?? true else { return nil }
        let generation = UUID()
        var liveConnectionGeneration = generation
        let ticketMacDeviceID = ticket.macDeviceID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedMacDeviceID = pairedMacDeviceID
            ?? (ticketMacDeviceID.isEmpty ? nil : ticketMacDeviceID)
        let previousForegroundKeyBeforeConnect = foregroundOrRecoveryMacKey
        let currentFocusedConnection: MacConnection? =
            foregroundMacDeviceID.flatMap { macID in
                guard let connection = connections[macID],
                      connection.client === remoteClient else { return nil }
                return connection
            }
        func isConnectCurrent() -> Bool {
            isCurrentConnectionAttempt(generation) && (ifStillCurrent?() ?? true)
        }
        connectionAttemptGeneration = generation
        connectionGeneration = generation
        await releaseConnectionAttemptClientForReplacement()
        guard isConnectCurrent() else { return nil }
        diagnosticLog?.record(DiagnosticEvent(.connect))
        cancelRemoteOperationTasks()
        rawTerminalInputBuffer.clear()
        terminalInputRPCPipeline.clear()
        resumeRawTerminalInputDrainWaiters()
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        // Per-Computer Direct enforcement: stored-Mac reconnects resolve the
        // allowlist from their freshly loaded row and pass it in; ticket
        // dials resolve it here from the published pairing list, using the
        // caller's pairing identity so a sibling build sharing the device id
        // cannot supply the wrong method. `nil` means the target's method
        // pins no addresses (automatic, or a legacy pairing without an Iroh
        // identity).
        let directOnlyDialCandidates = directOnlyDialCandidates
            ?? irohMethodPinnedDialCandidates(
                forMacDeviceID: requestedMacDeviceID ?? ticket.macDeviceID,
                instanceTag: instanceTagExpectation.expectedTag
            )
        let supportedRoutes = supportedRoutes(
            for: ticket,
            supportedKinds: supportedKinds,
            legacyTailscaleRoutes: legacyTailscaleRoutes,
            userTailscalePairingAuthorizations: userTailscalePairingAuthorizations,
            directOnly: directOnlyDialCandidates != nil,
            pairedMacDeviceID: requestedMacDeviceID,
            instanceTag: instanceTagExpectation.expectedTag
        )
        guard directOnlyDialCandidates?.isEmpty != true,
              let firstRoute = supportedRoutes.first else {
            // No route kind this build can dial: set the specific category;
            // the caller records the matching analytics reason from it.
            connectionError = MobilePairingFailureCategory.noSupportedRoute.message
            connectionErrorGuidance = MobilePairingFailureCategory.noSupportedRoute.guidance
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            diagnosticLog?.record(DiagnosticEvent(
                .routeUnavailable,
                a: DiagnosticTransportKind.unknown.rawValue,
                b: DiagnosticFailureKind.unsupportedRoute.rawValue
            ))
            clearRemoteConnectionContext()
            return .noSupportedRoute
        }
        let foregroundReservation = ForegroundConnectionAttemptReservation(
            id: generation,
            requestedMacDeviceID: requestedMacDeviceID,
            instanceTagExpectation: instanceTagExpectation,
            routes: supportedRoutes
        )
        foregroundConnectionAttemptReservation = foregroundReservation
        defer {
            if foregroundConnectionAttemptReservation?.id == generation {
                foregroundConnectionAttemptReservation = nil
            }
        }
        // A control pass can select this route before foreground intent is
        // published, then suspend during transport admission. Cancel and join
        // those exact flights before the foreground creates its client.
        let conflictingControlFlights = secondaryMacEstablishmentFlights
            .filter { foregroundReservation.conflicts(with: $0.value.mac) }
        for (_, flight) in conflictingControlFlights {
            flight.task.cancel()
        }
        for (key, flight) in conflictingControlFlights {
            _ = await flight.task.value
            if secondaryMacEstablishmentFlights[key]?.id == flight.id {
                secondaryMacEstablishmentFlights[key] = nil
            }
        }
        guard isConnectCurrent() else { return nil }
        let targetsCurrentLogicalMac =
            currentFocusedConnection.map { connection in
                requestedMacDeviceID.map {
                    cmxCanonicalDeviceID($0)
                        == cmxCanonicalDeviceID(connection.macDeviceID)
                } ?? false
            } ?? false
        let targetsCurrentPhysicalRoute =
            currentFocusedConnection.map { connection in
                supportedRoutes.contains {
                    connection.client.sharesPhysicalTransportRoute(with: $0)
                }
            } ?? false
        // A different Mac on a different physical route can authenticate while
        // the current focus stays live. Same-Mac and same-route targets must
        // first transfer the old route lease to cleanup, including anonymous
        // tickets whose logical identity is not known until host status.
        let previousFocusedConnection =
            targetsCurrentLogicalMac || targetsCurrentPhysicalRoute
                ? nil
                : currentFocusedConnection
        // No connect-time expiry gate: a pairing QR never expires (new QRs
        // carry no expiry at all), and the host authorizes by Stack account,
        // not ticket age. Expiry still gates the RPC-minted attach token at
        // its point of use (`MobileCoreRPCClient.requestDataWithAuth`).
        var candidateTicket = ticket
        var candidateRoute = firstRoute
        var candidateHostName = placeholderHostName(
            for: ticket,
            firstRoute: firstRoute
        )
        if previousFocusedConnection == nil {
            activeTicket = candidateTicket
            activeRoute = candidateRoute
            connectedHostName = candidateHostName
        }
        // Keep the current Mac alive while a different Mac authenticates. On
        // success it is demoted in-place to control-only; on failure the caller
        // can still tear it down through the ordinary connection-error path.
        // Retiring it here would strand an Iroh control owner long enough for the
        // replacement background dial to time out against that same peer.
        if previousFocusedConnection == nil {
            await releaseRemoteClientForReplacement()
            guard isConnectCurrent() else { return nil }
        }

        guard let runtime else {
            guard isConnectCurrent() else { return nil }
            clearPairingError()
            applyPreviewTicket(ticket, route: firstRoute)
            connectionState = .connected
            markMacConnectionHealthy()
            return nil
        }

        let workspaceListRequests = try initialWorkspaceListRequests(for: ticket)
        // Stack auth gates plaintext requests. Decide its transport authority
        // per attempted route so a generic fallback cannot inherit loopback or
        // grandfathered-Tailscale bearer permission.
        let routeAllowsStackAuthFallbackOverride = allowsStackAuthFallback
        let connectionAttemptStartedAt = pairingAttemptStartedAt
        var lastError: (any Error)?
        var displacedControlReservations: [SecondaryMacSubscription] = []
        let displacedControlReservationHolder = UUID()
        defer {
            for displacedControlReservation in displacedControlReservations {
                displacedControlReservation.transportDrainReservationHolders
                    .remove(displacedControlReservationHolder)
                if displacedControlReservation
                        .transportDrainReservationHolders.isEmpty,
                   secondaryMacDrainReservation(
                       for: displacedControlReservation.ownerKey
                   ) === displacedControlReservation,
                   displacedControlReservation.hasCompletedTransportDrain {
                    finishRetiredSecondaryPromotionCandidate(
                        displacedControlReservation,
                        forceRemovalDuringMacSwitch: true
                    )
                }
            }
        }
        // An in-flight secondary establishment owns its route's connect lease
        // from dial until it publishes or fails, and during that window it is
        // in neither the live registry nor the drain reservations. Settle it
        // first so the foreground dial drains whatever it publishes instead of
        // dialing into an instantaneous `.connectAttemptGated` refusal.
        let conflictingEstablishmentFlights =
            secondaryMacEstablishmentFlights.values.filter { flight in
                let sameRequestedDevice = requestedMacDeviceID.map {
                    cmxCanonicalDeviceID(flight.mac.macDeviceID)
                        == cmxCanonicalDeviceID($0)
                } ?? false
                return sameRequestedDevice
                    || flight.mac.routes.contains { flightRoute in
                        supportedRoutes.contains {
                            MobileCoreRPCClient.routesSharePhysicalTransport(
                                flightRoute,
                                $0
                            )
                        }
                    }
            }
        if !conflictingEstablishmentFlights.isEmpty {
            for flight in conflictingEstablishmentFlights {
                _ = await flight.task.value
            }
            guard isConnectCurrent() else { return nil }
        }
        // A fresh same-peer dial cannot acquire the Iroh session while any
        // warm control client owns one of its physical routes. Logical device
        // ids are only a fast path because anonymous tickets and renamed Macs
        // may not match the registry key until host status authenticates them.
        var drainCandidates: [SecondaryMacSubscription] = []
        var seenDrainCandidates: Set<ObjectIdentifier> = []
        func appendDrainCandidate(
            _ subscription: SecondaryMacSubscription
        ) {
            guard seenDrainCandidates.insert(
                ObjectIdentifier(subscription)
            ).inserted else {
                return
            }
            drainCandidates.append(subscription)
        }
        if let requestedMacDeviceID {
            // Scope the requested fast path to the EXACT pairing this dial
            // targets. A sibling build's healthy warm control connection on
            // the same physical Mac must stay untouched; genuinely shared
            // physical routes are still drained by the route loops below.
            let requestedOwnerKey: MacPairingKey
            switch instanceTagExpectation {
            case .preserve(let tag), .require(let tag):
                requestedOwnerKey = MacPairingKey(
                    macDeviceID: requestedMacDeviceID,
                    instanceTag: tag
                )
            case .adopt:
                requestedOwnerKey = MacPairingKey(
                    macDeviceID: requestedMacDeviceID,
                    instanceTag: nil
                )
            }
            if let reservation = secondaryMacDrainReservation(
                for: requestedOwnerKey
            ) {
                appendDrainCandidate(reservation)
            }
            if let liveControl = secondaryMacSubscriptions[requestedOwnerKey] {
                appendDrainCandidate(liveControl)
            }
        }
        for (_, subscription) in secondaryMacSubscriptions
            where supportedRoutes.contains(where: {
                subscription.client.sharesPhysicalTransportRoute(with: $0)
            }) {
            appendDrainCandidate(subscription)
        }
        for subscription in secondaryMacDrainReservations.values
            where supportedRoutes.contains(where: {
                subscription.client.sharesPhysicalTransportRoute(with: $0)
            }) {
            appendDrainCandidate(subscription)
        }

        var drainOperations: [SecondaryMacTransportDrainOperation] = []
        for candidate in drainCandidates {
            var displaced = secondaryMacDrainReservation(
                for: candidate.ownerKey
            )
            if displaced == nil,
               secondaryMacSubscriptions[candidate.ownerKey] === candidate {
                guard beginSecondaryMacDrainReservation(candidate) else {
                    return nil
                }
                displaced = secondaryMacDrainReservation(
                    for: candidate.ownerKey
                )
            }
            guard let displaced,
                  displaced === candidate else {
                continue
            }
            displacedControlReservations.append(displaced)
            displaced.transportDrainReservationHolders.insert(
                displacedControlReservationHolder
            )
            drainOperations.append(
                secondaryMacTransportDrainOperation(displaced)
            )
        }
        let drainWaiters = drainOperations.map { operation in
            Task { @MainActor in
                await operation.wait(
                    nanoseconds: connectionHandoffDrainTimeoutNanoseconds
                )
            }
        }
        defer {
            for waiter in drainWaiters {
                waiter.cancel()
            }
        }
        for waiter in drainWaiters {
            let transportDrained = await waiter.value
            guard isConnectCurrent() else {
                return nil
            }
            if Task.isCancelled {
                throw CancellationError()
            }
            guard transportDrained else {
                throw MobileShellConnectionError.requestTimedOut
            }
        }
        routeLoop: for route in supportedRoutes {
            candidateRoute = route
            if previousFocusedConnection == nil {
                activeRoute = route
            }
            mobileShellLog.info("pairing trying route kind=\(route.kind.rawValue, privacy: .public) endpoint=\(route.endpoint.logDescription, privacy: .private)")
            let legacyTailscaleAuthorizationEvidence = Self
                .legacyTailscaleAuthorizationEvidence(
                    for: route,
                    macDeviceID: ticket.macDeviceID,
                    persistedRoutes: legacyTailscaleRoutes
                )
            let userTailscalePairingAuthorization = legacyTailscaleAuthorizationEvidence == nil
                ? Self.userTailscalePairingAuthorization(
                    for: route,
                    authorizations: userTailscalePairingAuthorizations
                )
                : nil
            let client = MobileCoreRPCClient(
                runtime: runtime,
                route: route,
                ticket: ticket,
                allowsStackAuthFallback: routeAllowsStackAuthFallbackOverride
                    ?? MobileShellRouteAuthPolicy.routeAllowsStackAuth(route),
                legacyTailscaleAuthorizationEvidence: legacyTailscaleAuthorizationEvidence,
                userTailscalePairingAuthorization: userTailscalePairingAuthorization,
                irohDirectOnlyDialCandidates: directOnlyDialCandidates,
                connectAttemptRegistry: connectAttemptRegistry,
                stackTokenGate: stackTokenGate,
                stackTokenForceRefreshGate: stackTokenForceRefreshGate,
                transportConnectObserver: transportConnectDiagnosticObserver(
                    peerID: ticket.macDeviceID
                )
            )
            if let previousAttemptClient =
                replaceConnectionAttemptClientOwnership(with: client) {
                await previousAttemptClient.disconnect()
                guard isConnectCurrent() else {
                    await client.disconnect()
                    return nil
                }
            }
            defer {
                clearConnectionAttemptClient(ifMatching: client)
            }
            for workspaceListRequest in workspaceListRequests {
                do {
                    let requestTimeoutNanoseconds: UInt64
                    if let connectionAttemptStartedAt {
                        requestTimeoutNanoseconds = Self.boundedPairingRequestTimeoutNanoseconds(
                            runtime: runtime,
                            attemptStartedAt: connectionAttemptStartedAt
                        )
                        guard requestTimeoutNanoseconds > 0 else {
                            throw MobileShellConnectionError.requestTimedOut
                        }
                    } else {
                        requestTimeoutNanoseconds = runtime.pairingRequestTimeoutNanoseconds
                    }
                    let exchange = try await client.sendRequestAndAuthenticatedHostStatus(
                        workspaceListRequest.data,
                        timeoutNanoseconds: requestTimeoutNanoseconds,
                        hostStatusTimeoutNanoseconds: {
                            if let connectionAttemptStartedAt {
                                return Self.boundedPairingRequestTimeoutNanoseconds(
                                    runtime: runtime,
                                    attemptStartedAt: connectionAttemptStartedAt
                                )
                            }
                            return runtime.pairingRequestTimeoutNanoseconds
                        }
                    )
                    let response = try MobileSyncWorkspaceListResponse.decode(exchange.response)
                    guard isConnectCurrent() else {
                        await client.disconnect()
                        return nil
                    }
                    // Bind the route to the authenticated Mac process before
                    // persisting or labeling workspaces. A stale A endpoint may
                    // now be served by tag B on the same physical Mac.
                    guard let status = try? MobileHostStatusResponse.decode(exchange.hostStatusResponse) else {
                        await client.disconnect()
                        lastError = MobileShellConnectionError.invalidResponse
                        recordHostAuthenticationFailure(route: route, failure: .protocolViolation)
                        continue routeLoop
                    }
                    let reportedDeviceID = status.macDeviceID?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let hasAuthenticatedIdentity = reportedDeviceID?.isEmpty == false
                    let reportedInstanceTag = hasAuthenticatedIdentity ? status.macInstanceTag : nil
                    guard authenticatedMacBuildIsCompatible(
                        instanceTag: reportedInstanceTag,
                        clientNamespace: status.macClientNamespace,
                        macAppVersion: status.macAppVersion,
                        client: client
                    ) else {
                        mobileShellLog.error(
                            "rejecting route from incompatible Mac build reported=\(reportedInstanceTag ?? "missing", privacy: .public)"
                        )
                        await client.disconnect()
                        lastError = MobileShellConnectionError.rpcError(
                            "build_incompatible",
                            "Mac build is incompatible with this iOS build"
                        )
                        recordHostAuthenticationFailure(route: route, failure: .protocolViolation)
                        continue routeLoop
                    }
                    let authority = macInstanceTagAuthority.resolve(
                        expectation: instanceTagExpectation,
                        reportedInstanceTag: reportedInstanceTag
                    )
                    guard case .accept(let resolvedInstanceTag) = authority else {
                        mobileShellLog.error(
                            "rejecting route with mismatched Mac instance tag expected=\(String(describing: instanceTagExpectation), privacy: .public) reported=\(reportedInstanceTag ?? "missing", privacy: .public)"
                        )
                        await client.disconnect()
                        lastError = MobileShellConnectionError.invalidResponse
                        recordHostAuthenticationFailure(route: route, failure: .identityMismatch)
                        continue routeLoop
                    }
                    let ticketDeviceID = ticket.macDeviceID
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let expectedDeviceID = pairedMacDeviceID ?? (ticketDeviceID.isEmpty ? nil : ticketDeviceID)
                    if await adoptWouldConflictWithStoredInstanceAuthority(
                        expectation: instanceTagExpectation,
                        reportedInstanceTag: reportedInstanceTag,
                        macDeviceID: reportedDeviceID ?? expectedDeviceID
                    ) {
                        await client.disconnect()
                        lastError = MobileShellConnectionError.invalidResponse
                        recordHostAuthenticationFailure(route: route, failure: .identityMismatch)
                        continue routeLoop
                    }
                    if let expectedDeviceID,
                       hasAuthenticatedIdentity,
                       !macInstanceTagAuthority.authenticatedDeviceMatches(
                           reportedDeviceID: reportedDeviceID,
                           expectedDeviceID: expectedDeviceID
                       ) {
                        mobileShellLog.error("rejecting route with mismatched Mac device identity")
                        await client.disconnect()
                        lastError = MobileShellConnectionError.invalidResponse
                        recordHostAuthenticationFailure(route: route, failure: .identityMismatch)
                        continue routeLoop
                    }
                    if case .preserve = instanceTagExpectation,
                       !hasAuthenticatedIdentity {
                        // A known authority may tolerate an authenticated older
                        // Mac omitting only the tag. No response or identity-free
                        // public status cannot prove the stale port still serves it.
                        await client.disconnect()
                        lastError = MobileShellConnectionError.invalidResponse
                        recordHostAuthenticationFailure(route: route, failure: .identityMismatch)
                        continue routeLoop
                    }
                    if case .require = instanceTagExpectation,
                       (!hasAuthenticatedIdentity || reportedInstanceTag == nil) {
                        await client.disconnect()
                        lastError = MobileShellConnectionError.invalidResponse
                        recordHostAuthenticationFailure(route: route, failure: .identityMismatch)
                        continue routeLoop
                    }
                    let resolvedTicket = Self.ticket(
                        ticket,
                        adoptingReportedDeviceID: reportedDeviceID
                    )
                    candidateTicket = resolvedTicket
                    if previousFocusedConnection == nil {
                        activeTicket = resolvedTicket
                    }
                    let reportedName = hasAuthenticatedIdentity ? status.macDisplayName : nil
                    if let reportedName = reportedName?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !reportedName.isEmpty {
                        candidateHostName = reportedName
                        if previousFocusedConnection == nil {
                            connectedHostName = reportedName
                        }
                    }
                    let tagUpdate: PairedMacInstanceTagUpdate
                    if reportedInstanceTag != nil {
                        tagUpdate = .replace(resolvedInstanceTag)
                    } else if case .adopt = instanceTagExpectation {
                        tagUpdate = .preserveOnlyIfUnclaimed
                    } else {
                        tagUpdate = .preserve
                    }
                    let userAuthorizedTailscaleRoutes = ticket.routes.filter { ticketRoute in
                        Self.userTailscalePairingAuthorization(
                            for: ticketRoute,
                            authorizations: userTailscalePairingAuthorizations
                        ) != nil
                    }
                    let accepted = await persistPairedMacFromTicket(
                        resolvedTicket,
                        instanceTagUpdate: tagUpdate,
                        displayNameOverride: reportedName,
                        userAuthorizedTailscaleRoutes: userAuthorizedTailscaleRoutes,
                        ifStillCurrent: isConnectCurrent
                    )
                    guard accepted else {
                        await client.disconnect()
                        lastError = MobileShellConnectionError.invalidResponse
                        continue routeLoop
                    }
                    diagnosticLog?.record(DiagnosticEvent(
                        .hostAuthenticated,
                        surface: DiagnosticCorrelation().handle(for: resolvedTicket.macDeviceID),
                        a: DiagnosticTransportKind(route.kind).rawValue
                    ))
                    guard isConnectCurrent() else {
                        await client.disconnect()
                        return nil
                    }
                    let resolvedForegroundMacID = resolvedTicket.foregroundMacID(
                        hint: pairedMacDeviceID
                    )
                    let authenticatedCapabilities = Set(status.capabilities)
                    if let previousFocusedConnection {
                        let resolvesToSameMac = !resolvedForegroundMacID.isEmpty
                            && cmxCanonicalDeviceID(previousFocusedConnection.macDeviceID)
                                == cmxCanonicalDeviceID(resolvedForegroundMacID)
                        // Remove the old terminal registration before exposing
                        // the new focused client. A different or anonymous
                        // target can retain the old client as control-only; a
                        // same-Mac redial must disconnect the superseded client.
                        clearPendingTerminalInputForFocusChange()
                        let terminalStopped = await prepareFocusedConnectionForHandoff(
                            previousFocusedConnection
                        )
                        guard isConnectCurrent() else {
                            await client.disconnect()
                            invalidateFocusedConnectionAfterAbortedHandoff(
                                previousFocusedConnection
                            )
                            return nil
                        }
                        let retainPreviousAsControl =
                            terminalStopped && !resolvesToSameMac
                                ? await canRetainFocusedConnectionInControlPool(
                                    previousFocusedConnection,
                                    vacatingControlOwnerKey:
                                        displacedControlReservations
                                            .first?.ownerKey
                                )
                                : false
                        guard isConnectCurrent() else {
                            await client.disconnect()
                            invalidateFocusedConnectionAfterAbortedHandoff(
                                previousFocusedConnection
                            )
                            return nil
                        }
                        await commitFocusedConnectionHandoff(
                            previousFocusedConnection,
                            terminalStopped: terminalStopped,
                            retainAsControl: retainPreviousAsControl
                        )
                        guard isConnectCurrent() else {
                            await client.disconnect()
                            return nil
                        }
                        liveConnectionGeneration =
                            adoptPooledRemoteClient(client)
                    } else {
                        replaceRemoteClient(with: client)
                    }
                    activeTicket = candidateTicket
                    connectedHostName = candidateHostName
                    let previousForegroundDeviceIDForFeedReset = foregroundMacDeviceID
                    let previousForegroundTagForFeedReset = activeMacInstanceTag
                    activeMacInstanceTag = resolvedInstanceTag
                    resetForegroundNotificationFeedIfInstanceChanged(
                        previousDeviceID: previousForegroundDeviceIDForFeedReset,
                        previousTag: previousForegroundTagForFeedReset,
                        newDeviceID: resolvedForegroundMacID.isEmpty
                            ? previousForegroundDeviceIDForFeedReset
                            : resolvedForegroundMacID,
                        newTag: resolvedInstanceTag
                    )
                    // Mirror of the promotion path: the foreground refetches
                    // its feed under the bare device key, so a secondary-era
                    // pairing-keyed snapshot for THIS target would linger as a
                    // duplicate source that bulk mutations cannot clear.
                    if !resolvedForegroundMacID.isEmpty {
                        let takeoverPairingID = MobilePairedMac.pairingID(
                            macDeviceID: resolvedForegroundMacID,
                            instanceTag: resolvedInstanceTag
                        )
                        if takeoverPairingID != resolvedForegroundMacID {
                            removeNotificationFeedSnapshot(
                                macDeviceID: takeoverPairingID
                            )
                        }
                    }
                    prepareTerminalThemeRevisionAuthority(
                        macInstanceTag: resolvedInstanceTag, producerEpoch: status.terminalThemeRevisionEpoch,
                        connectionID: liveConnectionGeneration.uuidString
                    )
                    clearPairingError()
                    // Set the foreground Mac id BEFORE applying the list so the
                    // per-Mac state is keyed to THIS Mac, not the previously-
                    // foreground Mac (or the anonymous key). Otherwise switching
                    // from Mac A to Mac B writes B's workspaces under A's key, and
                    // once the id flips the derived list reads a stale/empty B
                    // snapshot. Anonymous (empty-id) tickets keep the anonymous key. A
                    // manual fallback ticket carries a synthetic `manual-…` id, so
                    // prefer the caller's real paired-Mac id when it is known.
                    let previousForegroundKey = previousForegroundKeyBeforeConnect
                    if resolvedForegroundMacID.isEmpty {
                        // An anonymous authenticated target cannot inherit the
                        // prior Mac's identity or focused registry entry.
                        foregroundMacDeviceID = nil
                    } else {
                        foregroundMacDeviceID = resolvedForegroundMacID
                    }
                    supportedHostCapabilities = authenticatedCapabilities
                    phonePushMacStatus = status.phonePush
                    // Publish transport selection with the authenticated
                    // capability snapshot before exposing `.connected`.
                    // The listener reuses this same status below, but starts in
                    // a task; leaving `.rawBytes` until that task runs creates a
                    // transient capability/state contradiction.
                    terminalOutputTransport =
                        Self.resolvedTerminalOutputTransport(
                            capabilities: authenticatedCapabilities,
                            terminalFidelity: status.terminalFidelity
                        )
                    applyRemoteWorkspaceList(
                        response,
                        preferActiveTicketTarget: workspaceListRequest.preferActiveTicketTarget,
                        forceForegroundSelection:
                            previousForegroundKey != foregroundMacKey,
                        // Scoped requests omit groups; only a non-scoped (full) list
                        // is authoritative for the device-local collapse store.
                        groupsAreAuthoritative: !workspaceListRequest.isScoped
                    )
                    // Drop the now-stale previous-foreground/anonymous snapshot so it
                    // doesn't linger in the aggregate (it's re-added as a secondary
                    // below if still reachable).
                    dropStalePreviousForeground(previousForegroundKey)
                    syncSelectedTerminalForWorkspace()
                    // Publish the route only after the target client, identity,
                    // capabilities, and workspace mapping are coherent. Its
                    // didSet may restart mounted terminal lanes.
                    activeRoute = candidateRoute
                    connectionState = .connected
                    markMacConnectionHealthy()
                    // Reuse the authenticated status response that bound this
                    // route to its Mac instance. The event listener needs the
                    // same payload for capability negotiation, so asking again
                    // here only adds a second connect-time round trip and can
                    // observe a different process during a rapid dev restart.
                    startTerminalRefreshPolling(initialHostStatus: status)
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
                    diagnosticLog?.record(DiagnosticEvent(
                        .rpcReady,
                        surface: DiagnosticCorrelation().handle(for: resolvedTicket.macDeviceID),
                        ms: connectionAttemptStartedAt.map {
                            UInt32(clamping: max(0, Int(Date().timeIntervalSince($0) * 1_000)))
                        },
                        a: DiagnosticTransportKind(route.kind).rawValue
                    ))
                    // Record this as the foreground entry in the per-Mac
                    // connection pool (P2). Anonymous (empty-id) tickets are not
                    // pooled, since a per-Mac key is required to aggregate. Keyed by
                    // the resolved real id (not the synthetic manual ticket id) so the
                    // pool entry matches the foreground/aggregation key.
                    if !resolvedForegroundMacID.isEmpty {
                        installFocusedConnection(MacConnection(
                            macDeviceID: resolvedForegroundMacID,
                            ticket: resolvedTicket,
                            route: route,
                            client: client,
                            generation: liveConnectionGeneration,
                            displayName: connectedHostName,
                            instanceTag: activeMacInstanceTag,
                            supportedHostCapabilities: authenticatedCapabilities,
                            actionCapabilities: Self.workspaceActionCapabilities(
                                from: authenticatedCapabilities,
                                allowsMacScopedMutations: allowsMacScopedWorkspaceMutations
                            )
                        ))
                    }
                    // Aggregate the user's other Macs' workspaces in the background.
                    // Best-effort; never blocks the foreground connect.
                    if !isReconnectingStoredMac {
                        self.scheduleSecondaryAggregation(
                            discoverLivePeers: true
                        )
                    }
                    diagnosticLog?.record(DiagnosticEvent(.pairOk))
                    if workspaceListRequest.isScoped {
                        scheduleFullWorkspaceListRefreshIfAvailable(
                            client: client,
                            route: route,
                            generation: liveConnectionGeneration
                        )
                    }
                    return nil
                } catch {
                    lastError = error
                    guard isConnectCurrent() else {
                        await client.disconnect()
                        return nil
                    }
                    mobileShellLog.error(
                        "pairing route failed kind=\(route.kind.rawValue, privacy: .public) endpoint=\(route.endpoint.logDescription, privacy: .private) scoped=\(workspaceListRequest.isScoped ? 1 : 0, privacy: .public): \(String(describing: error), privacy: .private)"
                    )
                    let failure = Self.diagnosticFailureKind(for: error)
                    if failure == .identityMismatch
                        || failure == .admissionDenied
                        || failure == .authorizationFailed
                        || failure == .accountMismatch {
                        recordHostAuthenticationFailure(route: route, failure: failure)
                    }
                    // An unreachable-class iroh route failure is staleness
                    // evidence: drop any reusable discovery snapshot for this
                    // Mac so the NEXT attempt rebuilds its dial plan from a
                    // fresh broker fetch instead of redialing a corpse route.
                    // The transport pool reports most dial failures itself,
                    // but this request deadline cancels an in-flight dial (the
                    // pool then sees only a cancellation), so the owner that
                    // classified the outcome reports it too.
                    if route.kind == .iroh,
                       !ticket.macDeviceID.isEmpty,
                       Self.routeFailureIndicatesStaleDiscovery(failure) {
                        await personalIrohDiscovery?.invalidateDiscovery(
                            forMacDeviceID: ticket.macDeviceID
                        )
                    }
                }
            }
            // This route exhausted every workspace-list request without being
            // adopted. Close its persistent transport before trying another
            // route so an Iroh session-pool owner cannot survive off-screen.
            await client.disconnect()
        }

        // One event per exhausted connect: a second `.rpcFailed` record here
        // would double the incident policy's consecutive-failure streak and
        // burn a second signature-cooldown gate for the same underlying error.
        diagnosticLog?.record(DiagnosticEvent(
            .pairFail,
            a: activeRoute.map { DiagnosticTransportKind($0.kind).rawValue }
                ?? DiagnosticTransportKind.unknown.rawValue,
            b: Self.diagnosticFailureKind(for: lastError).rawValue
        ))
        throw lastError ?? MobileShellConnectionError.connectionClosed
    }

    private struct WorkspaceListRequest {
        var data: Data
        var isScoped: Bool
        var preferActiveTicketTarget: Bool
    }

    private func supportedRoutes(
        for ticket: CmxAttachTicket,
        supportedKinds: [CmxAttachTransportKind],
        legacyTailscaleRoutes: [CmxAttachRoute] = [],
        userTailscalePairingAuthorizations: [CmxUserTailscalePairingAuthorization] = [],
        directOnly: Bool = false,
        pairedMacDeviceID: String? = nil,
        instanceTag: String? = nil
    ) -> [CmxAttachRoute] {
        let orderedRoutes = CmxAttachRoute.addingIrohPrivatePaths(
            to: ticket.routes,
            observedAt: Date()
        ).sorted(by: Self.routeSortsBefore)
        let supportedRoutes: [CmxAttachRoute]
        if supportedKinds.isEmpty {
            supportedRoutes = orderedRoutes
        } else {
            let supportedKinds = Set(supportedKinds)
            supportedRoutes = orderedRoutes.filter { route in
                supportedKinds.contains(route.kind)
            }
        }
        // The explicit Tailscale method is strict: only authorized Tailscale
        // destinations may be dialed, and an unavailable route leaves the app
        // disconnected instead of silently switching to Iroh. The method is
        // the dialed Computer's own choice, falling back to the app default.
        // Resolve it with the caller's pairing identity when one is known:
        // sibling builds share a device id but choose methods independently,
        // so a bare device lookup could apply the wrong build's method.
        let ticketMethod = connectionMethod(
            forMacDeviceID: pairedMacDeviceID ?? ticket.macDeviceID,
            instanceTag: instanceTag
        )
        // Direct rides the Iroh lane EXCLUSIVELY (identity-checked,
        // encrypted; the transport dials only the user-enabled addresses):
        // no dev loopback and no host/port lane, so an unusable allowlist
        // fails closed instead of switching paths.
        if directOnly || ticketMethod == .direct {
            return supportedRoutes.filter { $0.kind == .iroh }
        }
        if ticketMethod == .tailscale {
            let authorizedTailscale = supportedRoutes.filter { route in
                Self.legacyTailscaleAuthorizationEvidence(
                    for: route,
                    macDeviceID: ticket.macDeviceID,
                    persistedRoutes: legacyTailscaleRoutes
                ) != nil
                    || Self.userTailscalePairingAuthorization(
                        for: route,
                        authorizations: userTailscalePairingAuthorizations
                    ) != nil
            }
            return authorizedTailscale
        }
        // The Iroh method is just as strict as Tailscale Only: no raw
        // host/port fallback, ever. Debug loopback rides alongside Iroh as
        // the dev-build convenience (compiled out of production route sets):
        // it is the same-machine lane, not a cross-method fallback, and an
        // Iroh endpoint advertising no relays and no direct addresses must
        // not starve it or a dev simulator can never pair.
        return supportedRoutes.filter { $0.kind == .iroh || $0.kind == .debugLoopback }
    }

    /// The user-entered pairing-code authorization covering `route`, if any.
    /// Anchored on the exact destination the code named; a device identity a
    /// code claims is self-reported and grants nothing.
    static func userTailscalePairingAuthorization(
        for route: CmxAttachRoute,
        authorizations: [CmxUserTailscalePairingAuthorization]
    ) -> CmxUserTailscalePairingAuthorization? {
        guard route.kind == .tailscale,
              case let .hostPort(host, port) = route.endpoint else {
            return nil
        }
        return authorizations.first { $0.authorizes(host: host, port: port) }
    }

    private func attachTicketIsUnexpired(
        _ ticket: CmxAttachTicket,
        now: Date
    ) -> Bool {
        !ticket.isExpired(at: now)
    }

    private func initialWorkspaceListParams(for ticket: CmxAttachTicket) -> [String: Any] {
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

    private func initialWorkspaceListRequests(for ticket: CmxAttachTicket) throws -> [WorkspaceListRequest] {
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

    private static func ticket(
        _ ticket: CmxAttachTicket,
        adoptingReportedDeviceID reportedDeviceID: String?
    ) -> CmxAttachTicket {
        guard ticket.macDeviceID.isEmpty,
              let reportedDeviceID = reportedDeviceID?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !reportedDeviceID.isEmpty,
              let adopted = try? CmxAttachTicket(
                version: ticket.version,
                workspaceID: ticket.workspaceID,
                terminalID: ticket.terminalID,
                macDeviceID: reportedDeviceID,
                macDisplayName: ticket.macDisplayName,
                macUserEmail: ticket.macUserEmail,
                macUserID: ticket.macUserID,
                macPairingCompatibilityVersion: ticket.macPairingCompatibilityVersion,
                macAppVersion: ticket.macAppVersion,
                macAppBuild: ticket.macAppBuild,
                routes: ticket.routes,
                expiresAt: ticket.expiresAt,
                authToken: ticket.authToken
              ) else {
            return ticket
        }
        return adopted
    }

    private func scheduleFullWorkspaceListRefreshIfAvailable(
        client: MobileCoreRPCClient,
        route: CmxAttachRoute,
        generation: UUID
    ) {
        guard workspaceListRefreshTask == nil else { return }
        let operationID = UUID()
        workspaceListRefreshOperationID = operationID
        workspaceListRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return false }
            defer {
                if self.workspaceListRefreshOperationID == operationID {
                    self.workspaceListRefreshTask = nil
                    self.workspaceListRefreshOperationID = nil
                }
            }
            return await self.refreshAllWorkspacesWithAttachTokenIfAvailable(
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
        activeMacInstanceTag = nil
        connectedHostName = ""
    }

    func clearRemoteConnectionContext(preservingOtherMacWorkspaceState: Bool = false) {
        connectionGeneration = UUID()
        connectionAttemptGeneration = UUID()
        // Capture the tagged foreground key BEFORE the identity clears below:
        // `foregroundMacKey` derives from `activeMacInstanceTag`, which
        // `clearActiveConnectionContext()` nils, and the offline retention
        // filter must keep the exact tagged entry.
        let offlineForegroundKey = foregroundMacKey
        focusedHandoffPreparedGenerations.removeAll()
        cancelRemoteOperationTasks()
        clearActiveConnectionContext()
        macConnectionStatus = .unavailable
        if let attemptClient =
            replaceConnectionAttemptClientOwnership(with: nil) {
            scheduleClientDisconnect(attemptClient)
        }
        // Drop the foreground entry from the connection pool (P2). Secondary
        // capabilities for other peers are torn down separately. A focused
        // peer may also own control, so remove both capabilities before its
        // shared physical client is disconnected.
        if let foreground = foregroundMacDeviceID,
           let focused = connections[foreground] {
            removeControlCapability(ifMatching: focused)
            macConnectionRegistry.setFocusedConnection(nil, for: focused.ownerKey)
        }
        replaceRemoteClient(with: nil)
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
        let offlineDeviceID = offlineForegroundKey.canonicalMacDeviceID
        let keysToDowngrade = workspacesByMac.keys.filter { key in
            key == offlineForegroundKey
                || (!preservingOtherMacWorkspaceState
                    && offlineForegroundKey != .anonymousForeground
                    && key.canonicalMacDeviceID == offlineDeviceID)
        }
        var updatedWorkspacesByMac = workspacesByMac
        for key in keysToDowngrade {
            guard var offline = updatedWorkspacesByMac[key] else { continue }
            offline.status = .unavailable
            offline.workspaceGroupsAreAuthoritative = false
            updatedWorkspacesByMac[key] = offline
        }
        workspacesByMac = updatedWorkspacesByMac
        rawTerminalInputBuffer.clear()
        terminalInputRPCPipeline.clear()
        resumeRawTerminalInputDrainWaiters()
    }

    /// Set `remoteClient` to a new value (possibly nil) and disconnect the
    /// previous one so we don't leak a persistent transport.
    func replaceRemoteClient(with newValue: MobileCoreRPCClient?) {
        if let previous = replaceRemoteClientOwnership(with: newValue) {
            scheduleClientDisconnect(previous)
        }
    }

    /// Replace shell ownership, then wait only until the old session has
    /// detached its transport and transferred the route lease to cleanup. The
    /// physical close remains asynchronous and bounded by the shared registry.
    func replaceRemoteClientAwaitingTeardownRegistration(
        with newValue: MobileCoreRPCClient?
    ) async {
        let previous = replaceRemoteClientOwnership(with: newValue)
        await previous?.disconnect()
    }

    /// Release the current foreground owner before a same-Mac or same-route
    /// replacement. Registry removal and synchronous retirement happen before
    /// the await; returning means the physical route lease has transferred to
    /// bounded cleanup and one recovery dial may proceed.
    func releaseRemoteClientForReplacement() async {
        let previous = remoteClient
        if let foregroundMacDeviceID,
           let focused = connections[foregroundMacDeviceID],
           focused.client === previous {
            removeControlCapability(ifMatching: focused)
            removeFocusedConnection(ifMatching: focused)
        }
        await replaceRemoteClientAwaitingTeardownRegistration(with: nil)
    }

    /// Retire the current pre-authentication candidate before a newer connect
    /// competes for the same physical route. The registry lease transfers to
    /// teardown before the replacement reaches transport admission.
    private func releaseConnectionAttemptClientForReplacement() async {
        let previous = replaceConnectionAttemptClientOwnership(with: nil)
        await previous?.disconnect()
    }

    private func clearConnectionAttemptClient(
        ifMatching client: MobileCoreRPCClient
    ) {
        guard connectionAttemptClient === client else { return }
        connectionAttemptClient = nil
    }

    private func replaceConnectionAttemptClientOwnership(
        with newValue: MobileCoreRPCClient?
    ) -> MobileCoreRPCClient? {
        let previous = connectionAttemptClient
        if let previous, previous !== newValue {
            previous.retire()
        }
        connectionAttemptClient = newValue
        return previous !== newValue ? previous : nil
    }

    private func scheduleClientDisconnect(_ client: MobileCoreRPCClient) {
        let id = UUID()
        clientDisconnectTasks[id] = Task { @MainActor [weak self] in
            await client.disconnect()
            self?.clientDisconnectTasks[id] = nil
        }
    }

    /// Publish one remote-client ownership change synchronously. Callers choose
    /// whether teardown registration is fire-and-forget or an awaited handoff.
    private func replaceRemoteClientOwnership(
        with newValue: MobileCoreRPCClient?
    ) -> MobileCoreRPCClient? {
        let previous = remoteClient
        if let previous, previous !== newValue {
            previous.retire()
        }
        remoteClient = newValue
        if previous !== newValue {
            terminalSubscriptionHandoffFences.removeAll()
        }
        return previous !== newValue ? previous : nil
    }

    /// Move focus to an already pooled client without retiring the previous
    /// client. Legacy callers clear terminal registrations before adoption;
    /// multiplexed Iroh handoffs preserve their per-client fences for cleanup.
    @discardableResult
    func adoptPooledRemoteClient(
        _ newValue: MobileCoreRPCClient,
        generation: UUID = UUID(),
        preservingTerminalHandoffFences: Bool = false
    ) -> UUID {
        guard remoteClient !== newValue else { return connectionGeneration }
        stopTerminalRefreshPolling()
        cancelRemoteOperationTasks()
        clearPendingTerminalInputForFocusChange()
        resetTerminalOutputTracking()
        // Authentication can stage the target while the old client remains
        // routable. Publish a fresh live generation at the actual swap so work
        // begun during staging cannot cross onto the target connection.
        connectionGeneration = generation
        remoteClient = newValue
        if !preservingTerminalHandoffFences {
            terminalSubscriptionHandoffFences.removeAll()
        }
        return connectionGeneration
    }

    /// Atomically replace any control owner with focus, then synchronously
    /// retire the displaced transport before its asynchronous close finishes.
    func installFocusedConnection(_ connection: MacConnection) {
        let displaced = macConnectionRegistry.transitionToFocused(connection)
        // The app has one focused role. Publishing its replacement resolves
        // any prepared marker left by the previous focus or a restore redial.
        focusedHandoffPreparedGenerations.removeAll()
        guard let displaced else { return }
        displaced.detachKeepingClient()
        guard displaced.client !== connection.client else { return }
        displaced.client.retire()
        scheduleClientDisconnect(displaced.client)
    }

    /// Move focus to a client that keeps its aggregate control subscription.
    /// The registry publishes one focused snapshot while both capabilities
    /// continue multiplexing over the same peer session.
    func installFocusedConnectionPreservingControl(
        _ connection: MacConnection
    ) -> Bool {
        guard macConnectionRegistry.transitionToFocusedPreservingControl(
            connection
        ) else {
            return false
        }
        focusedHandoffPreparedGenerations.removeAll()
        return true
    }

    /// Add control maintenance to the current focused client's existing peer
    /// session before its focus lease moves elsewhere.
    func installControlAlongsideFocus(
        _ subscription: SecondaryMacSubscription,
        replacing connection: MacConnection
    ) -> Bool {
        macConnectionRegistry.installControlAlongsideFocus(
            subscription,
            replacing: connection
        )
    }

    /// Atomically demote exactly the focused client that completed the terminal
    /// unsubscribe handshake. A newer focus owner wins and is never overwritten.
    func transitionFocusedConnectionToControl(
        _ subscription: SecondaryMacSubscription,
        replacing connection: MacConnection
    ) -> Bool {
        macConnectionRegistry.transitionToControl(
            subscription,
            replacing: connection,
            maximumControlCount: Self.maximumWarmControlConnectionCount
        )
    }

    func exchangePromotedControlForDemotedFocus(
        promotedControl: SecondaryMacSubscription,
        demotedControl: SecondaryMacSubscription,
        replacing focusedConnection: MacConnection
    ) -> Bool {
        macConnectionRegistry.exchangePromotedControlForDemotedFocus(
            promotedControl: promotedControl,
            demotedControl: demotedControl,
            replacing: focusedConnection
        )
    }

    func isFocusedConnectionCurrent(_ connection: MacConnection) -> Bool {
        macConnectionRegistry.isFocused(ifMatching: connection)
    }

    func registryOwnsClient(of connection: MacConnection) -> Bool {
        macConnectionRegistry.ownsClient(of: connection)
    }

    /// A demoted foreground can enter the warm pool only when it is still an
    /// online, visible pairing in the current account/team scope. The store
    /// read crosses the team-change boundary, so scope is revalidated afterward.
    func canRetainFocusedConnectionInControlPool(
        _ connection: MacConnection,
        vacatingControlOwnerKey: MacPairingKey? = nil
    ) async -> Bool {
        guard multiMacAggregationEnabled,
              let pairedMacStore,
              let scope = await currentScopeSnapshot(),
              let stored = try? await pairedMacStore.loadAll(
                  stackUserID: scope.userID,
                  teamID: scope.teamID
              ).first(where: {
                  cmxCanonicalDeviceID($0.macDeviceID)
                      == cmxCanonicalDeviceID(connection.macDeviceID)
                      && macInstanceTagAuthority.sameStoredAuthority(
                          $0.instanceTag,
                          connection.storedInstanceTag
                      )
              }),
              await isScopeCurrent(scope),
              await !isHiddenMacDeviceID(
                  stored.macDeviceID,
                  instanceTag: stored.instanceTag,
                  scope: scope
              ) else {
            return false
        }
        let alreadyHasControl = secondaryMacSubscriptions[
            connection.ownerKey
        ]?.client === connection.client
        guard alreadyHasControl || hasWarmControlCapacity(
            vacatingControlOwnerKey: vacatingControlOwnerKey
        ) else {
            return false
        }
        // Some injected/legacy compositions have no live-presence service.
        // Their current scoped pairing is the only available eligibility
        // authority. Production compositions with presence remain online-only.
        guard presence != nil else { return true }
        guard presenceMap.hasReceivedSnapshot else { return true }
        return presenceSummary(
            for: stored.macDeviceID,
            instanceTag: stored.instanceTag
        )?.online == true
    }

    private func hasWarmControlCapacity(
        vacatingControlOwnerKey: MacPairingKey?
    ) -> Bool {
        let vacatesControlSlot = vacatingControlOwnerKey.map { targetKey in
            secondaryMacSubscriptions.keys.contains(targetKey)
        } ?? false
        return warmControlPoolHasCapacity(
            currentControlCount: secondaryMacSubscriptions.count,
            vacatesControlSlot: vacatesControlSlot
        )
    }

    @discardableResult
    func removeFocusedConnection(ifMatching connection: MacConnection) -> Bool {
        let removed = macConnectionRegistry.removeFocused(
            ifMatching: connection
        )
        if removed {
            focusedHandoffPreparedGenerations.remove(connection.generation)
        }
        return removed
    }

    /// Remove only the control capability sharing this focused client's peer
    /// session. The caller retains responsibility for the physical disconnect.
    func removeControlCapability(ifMatching connection: MacConnection) {
        guard let subscription = secondaryMacSubscriptions[
            connection.ownerKey
        ], subscription.client === connection.client else {
            return
        }
        subscription.detachKeepingClient()
        _ = macConnectionRegistry.removeControlSubscription(
            ifMatching: subscription
        )
    }

    /// Cancel only the keyed keepalive RPC owned by this exact control
    /// capability. A replacement subscription under the same pairing wins.
    func cancelSecondaryControlReassertion(
        ifOwnedBy subscription: SecondaryMacSubscription
    ) {
        let ownerKey = subscription.ownerKey
        guard secondaryControlReassertionOwnerIDsByOwnerKey[ownerKey]
                == ObjectIdentifier(subscription) else {
            return
        }
        secondaryControlReassertionTasksByOwnerKey[ownerKey]?.cancel()
        secondaryControlReassertionTasksByOwnerKey[ownerKey] = nil
        secondaryControlReassertionTokensByOwnerKey[ownerKey] = nil
        secondaryControlReassertionOwnerIDsByOwnerKey[ownerKey] = nil
    }

    /// A superseded handoff may return after the old Mac has already
    /// acknowledged terminal unsubscription. If it is still the published
    /// foreground, retire that now-renderless connection so cancellation
    /// recovery performs a real redial instead of mistaking it for healthy.
    func invalidateFocusedConnectionAfterAbortedHandoff(
        _ connection: MacConnection
    ) {
        guard isFocusedConnectionCurrent(connection) else {
            focusedHandoffPreparedGenerations.remove(connection.generation)
            return
        }
        // A cancellation restore or newer connect publishes its generation
        // before replacing the old client. Leave the prepared marker intact so
        // that attempt repairs the terminal subscription instead of accepting
        // this renderless foreground as healthy.
        guard connectionGeneration == connection.generation,
              remoteClient === connection.client,
              foregroundMacDeviceID.map({
                  cmxCanonicalDeviceID($0)
                      == cmxCanonicalDeviceID(connection.macDeviceID)
              }) == true else {
            return
        }
        focusedHandoffPreparedGenerations.remove(connection.generation)
        removeControlCapability(ifMatching: connection)
        removeFocusedConnection(ifMatching: connection)
        if var offline = workspacesByMac[foregroundMacKey] {
            offline.status = .unavailable
            offline.workspaceGroupsAreAuthoritative = false
            workspacesByMac[foregroundMacKey] = offline
        }
        connectionState = .disconnected
        macConnectionStatus = .unavailable
        foregroundMacDeviceID = nil
        clearActiveConnectionContext()
        replaceRemoteClient(with: nil)
    }

    func cancelRemoteOperationTasks() {
        hostIdentityAdoptionTask?.cancel()
        hostIdentityAdoptionTask = nil
        terminalSubscriptionRefreshTask?.cancel()
        terminalSubscriptionRefreshTask = nil
        notificationReconcileTask?.cancel()
        notificationReconcileTask = nil
        createWorkspaceTask?.cancel()
        createWorkspaceTask = nil
        createWorkspaceTaskGroupID = nil
        createWorkspaceTaskSpec = nil
        createWorkspaceTaskID = nil
        createTerminalTask?.cancel()
        createTerminalTask = nil
        createTerminalTaskID = nil
        workspaceListRefreshTask?.cancel()
        workspaceListRefreshTask = nil
        workspaceListRefreshOperationID = nil
        pullToRefreshTask?.cancel()
        pullToRefreshTask = nil
        workspaceChangesSummaryDebounceTask?.cancel()
        workspaceChangesSummaryDebounceTask = nil
        workspaceChangesSummaryDebounceTaskID = nil
        workspaceChangesSummaryFetchTask?.cancel()
        workspaceChangesSummaryFetchTask = nil
        workspaceChangesSummaryFetchTaskID = nil
        workspaceChangesSummaryTrailingTask?.cancel()
        workspaceChangesSummaryTrailingTask = nil
        workspaceChangesSummaryTrailingTaskID = nil
        workspaceChangesSummaryTrailingDeadline = nil
        workspaceChangesSummaryTrailingExpiryByWorkspaceID = [:]
        workspaceChangesSummaryRefreshSchedulePolicy.reset()
        foregroundWorkspaceMutationRefreshTask?.cancel()
        foregroundWorkspaceMutationRefreshTask = nil
        foregroundWorkspaceMutationRefreshPending = false
        foregroundWorkspaceMutationRefreshGeneration = UUID()
        cancelAllTerminalReplayTasks()
    }

    private func resetTerminalOutputTracking() {
        cancelAllTerminalReplayTasks()
        effectiveViewportSizesBySurfaceID = [:]; reportedTerminalViewportSizesBySurfaceID = [:]
        // Keep viewport sequences for the account lifetime. A warm peer keeps
        // its Mac-side tombstone, while a reconnected peer safely accepts a
        // higher generation. The account boundary clears the owner-keyed map.
        // reportedViewportSizesByTerminalKey deliberately survives this reset:
        // geometry seeded before or between connections must still ride the
        // next connection's piggybacks (pre-connect reports are part of the
        // attach contract). Its dimensions may then travel generationless;
        // the Mac side refuses to let a generationless report supersede a
        // generation-carrying pin, so a stale survivor can pre-pin a fresh
        // connection at worst until the first dedicated report lands.
        deliveredTerminalByteEndSeqBySurfaceID = [:]
        terminalPreBarrierDeliveredEndSeqBySurfaceID = [:]
        terminalRenderGridBaselineReplayRequestCountsBySurfaceID = [:]
        terminalRenderGridBaselineReplayBarrierTokensBySurfaceID = [:]
        terminalAlternateRenderGridBaselineSurfaceIDs = []
        pendingTerminalByteEndSeqBySurfaceID = [:]
        pendingTerminalInputDroppedRenderGridSurfaceIDs = []
        terminalActiveScreenBySurfaceID = [:]
        diagnosedTerminalOutputSurfaceIDs = []
        terminalRenderGridHistoryContinuityBySurfaceID = [:]
        terminalMirrorHydrationNeededSurfaceIDs = []
        terminalReplaySurfaceIDsInFlight = []
        terminalReplayRequestIDsInFlightBySurfaceID = [:]
        cancelAllTerminalReplayBarrierWatchdogs()
        terminalReplayBarrierTokensInFlightBySurfaceID = [:]
        terminalReplayBarrierTokensBySurfaceID = [:]
        terminalReplayBarrierAckStreamTokensBySurfaceID = [:]
        terminalReplayBarrierDroppedOutputSurfaceIDs = []
        terminalReplayBarrierDroppedOutputCountsBySurfaceID = [:]
        terminalReplayBarrierAckCoveredDroppedOutputCountsBySurfaceID = [:]
        terminalViewportReplayBarrierPendingAckTokensBySurfaceID = [:]
        terminalReplayFailureRetryCountsBySurfaceID = [:]
        terminalReplayBarrierFollowUpCountsBySurfaceID = [:]
        terminalColdAttachReplayBarrierTokensBySurfaceID = [:]
        terminalColdReplayNeedsBarrierUpgradeSurfaceIDs = Set(terminalByteContinuationsBySurfaceID.keys)
        terminalOutputQueuesBySurfaceID = [:]
        terminalOutputStreamTokensBySurfaceID = terminalOutputStreamTokensBySurfaceID.mapValues { _ in UUID() }
        terminalFullReplacementSeqBySurfaceID = [:]
        terminalFullReplacementGenerationBySurfaceID = [:]
        terminalFullReplacementGeneration = 0
        terminalScrollQueueTokensBySurfaceID = [:]
        terminalScrollQueuesBySurfaceID = [:]
        terminalScrollbackPrefetchStatesBySurfaceID = [:]
        terminalOutputTransport = .rawBytes
        deactivateAllTerminalLanes()
        supportedHostCapabilities = []
        phonePushMacStatus = nil
        caffeineStatus = nil
        isCaffeineMutationInFlight = false
        caffeineMutationID = nil
        clearMacUpdateHint()
        terminalSubscriptionRefreshTask?.cancel()
        terminalSubscriptionRefreshTask = nil
        cancelTerminalInputAckResubscribeRetry()
        stopRenderGridLivenessWatchdog(listenerID: nil)
        lastTerminalEventAt = nil
    }

    /// The one shared entry every pairing flow funnels through, so it is also the
    /// single `ios_pairing_started` fire-site. `method` is `qr`/`manual`/
    /// `attach_url`; pass `nil` for non-instrumented internal flows (preview).
    private func beginPairingAttempt(method: String? = nil) -> UUID {
        let attemptID = beginPairingValidationAttempt(method: method)
        preparePairingConnectionAttempt()
        return attemptID
    }

    /// Supersede recovery and terminal work only after any non-destructive
    /// ticket probe has succeeded and a foreground replacement can proceed.
    private func preparePairingConnectionAttempt() {
        // Any explicit connect supersedes launch/network recovery, including a
        // recovery parked while the scene was inactive.
        pendingInactiveRecoveryTrigger = nil
        connectionRecoveryOwner.cancel()
        applyConnectionRecoveryOwnerState()
        invalidateStoredMacReconnectAttempt()
        connectionGeneration = UUID()
        connectionAttemptGeneration = UUID()
        cancelRemoteOperationTasks()
        rawTerminalInputBuffer.clear()
        terminalInputRPCPipeline.clear()
        resumeRawTerminalInputDrainWaiters()
        clearPairingError()
        clearPairingVersionWarning()
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
            recordAppEvent(.pairingStarted)
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
        let startedAt = pairingAttemptStartedAt
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
        recordAppEvent(
            .pairingSucceeded,
            correlationID: connectedMacDeviceID,
            startedAt: startedAt
        )
        pairingAttemptStartedAt = nil
        pairingAttemptMethod = nil
    }

    /// Emits `ios_pairing_failed` once for the in-flight attempt with a reason +
    /// phase, then clears the attempt timing so it can't double-fire.
    private func recordPairingFailed(
        reason: String,
        phase: String,
        failure: DiagnosticFailureKind = .unknown
    ) {
        guard let method = pairingAttemptMethod else { return }
        let startedAt = pairingAttemptStartedAt
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
        recordAppEvent(
            .pairingFailed,
            startedAt: startedAt,
            failure: failure
        )
        pairingAttemptStartedAt = nil
        pairingAttemptMethod = nil
    }

    private func isCurrentPairingAttempt(_ attemptID: UUID) -> Bool {
        pairingAttemptID == attemptID && isSignedIn
    }

    private func isCurrentConnectionAttempt(_ generation: UUID) -> Bool {
        generation == connectionAttemptGeneration && isSignedIn
    }

    private func beginMacSwitchAttempt() -> UUID {
        let attemptID = UUID()
        macSwitchCancelRestoreGeneration &+= 1
        macSwitchRestorePreviousOnCancelAttemptIDs.removeAll(keepingCapacity: true)
        macSwitchAttemptID = attemptID
        macSwitchAttemptSignInGeneration = signInGeneration
        if hasActiveMacConnection {
            macSwitchRestoreBaseline = nil
        }
        invalidatePairingAttempt()
        connectionAttemptGeneration = UUID()
        return attemptID
    }

    private func clearMacSwitchAttemptState(invalidateUnderlyingConnectionAttempt: Bool = false) {
        macSwitchCancelRestoreGeneration &+= 1
        macSwitchAttemptID = nil
        macSwitchAttemptSignInGeneration = nil
        macSwitchRestorePreviousOnCancelAttemptIDs.removeAll(keepingCapacity: true)
        macSwitchRestoreBaseline = nil
        if invalidateUnderlyingConnectionAttempt {
            invalidatePairingAttempt()
            connectionAttemptGeneration = UUID()
        }
    }

    @discardableResult
    private func restoreMacSwitchBaselineIfCancelled(
        _ attemptID: UUID,
        fallback: MobilePairedMac? = nil
    ) async -> Bool {
        if Task.isCancelled {
            _ = cancelMacSwitchAttempt(attemptID)
        }
        guard consumeMacSwitchRestorePreviousOnCancel(attemptID) else { return false }
        let restoreGeneration = macSwitchCancelRestoreGeneration
        let restored = await restorePreviousMacIfNeeded(
            macSwitchRestoreBaseline ?? fallback,
            cancelRestoreGeneration: restoreGeneration
        )
        macSwitchRestoreBaseline = nil
        return restored
    }

    private func consumeMacSwitchRestorePreviousOnCancel(_ attemptID: UUID) -> Bool {
        macSwitchRestorePreviousOnCancelAttemptIDs.remove(attemptID) != nil
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
        recordPairingFailed(
            reason: category.analyticsReason,
            phase: phase,
            failure: category.diagnosticFailureKind
        )
    }

    /// Preserve an existing saved pairing while explaining the one migration
    /// step the Mac still needs. This is deliberately distinct from an auth
    /// failure: signing out or deleting the pairing cannot make an older Mac
    /// publish an Iroh identity, and the same saved row becomes usable as soon
    /// as the Mac updates and republishes through the authenticated registry.
    private func applyStoredMacUpdateRequiredFailure(disconnect: Bool) {
        applyPairingFailure(.macUpdateRequired, phase: "migration")
        connectionRequiresReauth = false
        guard disconnect else { return }
        connectionState = .disconnected
        macConnectionStatus = .unavailable
        clearRemoteConnectionContext()
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
        pendingPairingVersionWarningWasUserEntered = false
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
        recordPairingFailed(
            reason: category?.analyticsReason ?? "other",
            phase: phase,
            failure: category?.diagnosticFailureKind ?? .unknown
        )
    }

    /// Surface an operational error (a request failing on an already-live
    /// connection, e.g. create-workspace) through the same classifier as
    /// pairing. Does NOT emit `ios_pairing_failed` (no attempt is in flight).
    func applyOperationalError(_ error: any Error) {
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

    func clearCreateWorkspaceTask(id: UUID) {
        guard createWorkspaceTaskID == id else { return }
        createWorkspaceTask = nil
        createWorkspaceTaskGroupID = nil
        createWorkspaceTaskSpec = nil
        createWorkspaceTaskID = nil
    }

    private func clearCreateTerminalTask(id: UUID) {
        guard createTerminalTaskID == id else { return }
        createTerminalTask = nil
        createTerminalTaskID = nil
    }

    func isCurrentRemoteOperation(client: MobileCoreRPCClient, generation: UUID) -> Bool {
        isCurrentRemoteConnection(client: client, generation: generation)
            && connectionState == .connected
    }

    private func isCurrentRemoteConnection(client: MobileCoreRPCClient, generation: UUID) -> Bool {
        generation == connectionGeneration
            && client === remoteClient
            && isSignedIn
    }

    func markMacConnectionHealthy() {
        guard connectionState == .connected else {
            macConnectionStatus = .unavailable
            return
        }
        let subscriptionIsValidated =
            terminalEventListenerID.map { listenerID in
                lastSuccessfulTerminalSubscription
                    == MobileTerminalSubscriptionValidation(
                        connectionGeneration: connectionGeneration,
                        listenerID: listenerID
                    )
            } ?? false
        let requiresSubscriptionValidation =
            runtime?.supportsServerPushEvents == true
                || terminalEventListenerID != nil
        // Creating or refreshing the push subscription is a secondary
        // readiness check. It must not demote an already-authenticated RPC
        // session to `reconnecting` while the ACK is in flight. A transient
        // subscription race otherwise blanks the workspace UI even though the
        // live Iroh client can still serve requests.
        guard !requiresSubscriptionValidation
                || subscriptionIsValidated
                || macConnectionStatus == .connected else {
            macConnectionStatus = .reconnecting
            connectionRecoveryFailed = false
            return
        }
        let foregroundKey = foregroundMacKey
        if var foregroundState = workspacesByMac[foregroundKey],
           foregroundState.status != .connected {
            foregroundState.status = .connected
            workspacesByMac[foregroundKey] = foregroundState
        }
        macConnectionStatus = .connected
        isRecoveringConnection = false
        connectionRecoveryFailed = false
        connectionRequiresReauth = false
    }

    @discardableResult
    func recordUsableTerminalSubscription(
        client: MobileCoreRPCClient,
        connectionGeneration: UUID,
        listenerID: UUID
    ) -> Bool {
        guard isCurrentRemoteOperation(
            client: client,
            generation: connectionGeneration
        ) else {
            return false
        }
        recordSuccessfulTerminalSubscription(
            connectionGeneration: connectionGeneration,
            listenerID: listenerID
        )
        markMacConnectionHealthy()
        return true
    }

    func markMacConnectionReconnecting() {
        guard connectionState == .connected, remoteClient != nil else {
            macConnectionStatus = .unavailable
            return
        }
        macConnectionStatus = .reconnecting
        if var foregroundState = workspacesByMac[foregroundMacKey] {
            foregroundState.workspaceGroupsAreAuthoritative = false
            workspacesByMac[foregroundMacKey] = foregroundState
        }
        isRecoveringConnection = true
        connectionRecoveryFailed = false
    }

    private func markMacConnectionUnavailable() {
        guard connectionState == .connected else {
            macConnectionStatus = .unavailable
            return
        }
        macConnectionStatus = .unavailable
        if var foregroundState = workspacesByMac[foregroundMacKey] {
            foregroundState.workspaceGroupsAreAuthoritative = false
            workspacesByMac[foregroundMacKey] = foregroundState
        }
        isRecoveringConnection = false
        connectionRecoveryFailed = true
    }

    func markMacConnectionUnavailableIfNeeded(after error: any Error) {
        guard MobileShellMacAvailabilityFailureClassifier().isAvailabilityFailure(error) else { return }
        markMacConnectionUnavailable()
    }

    /// Applies an availability failure only to the connection that produced it.
    /// A blocked transport write is definitive and enters the single recovery
    /// owner; an ordinary response timeout remains scoped to that one RPC.
    func handleMacAvailabilityFailureIfCurrent(
        after error: any Error,
        expectedClient: MobileCoreRPCClient,
        expectedGeneration: UUID
    ) {
        guard remoteClient === expectedClient,
              connectionGeneration == expectedGeneration,
              MobileShellMacAvailabilityFailureClassifier().isAvailabilityFailure(error) else {
            return
        }
        if case MobileShellConnectionError.transportWriteTimedOut = error {
            recoverDeadConnection(
                trigger: .transportWriteTimedOut,
                expectedClient: expectedClient
            )
        } else {
            markMacConnectionUnavailable()
        }
    }

    func syncSelectedTerminalForWorkspace() {
        guard let selectedWorkspace else {
            selectedTerminalID = nil
            return
        }
        if let selectedTerminalID,
           let selectedTerminal = selectedWorkspace.terminals.first(where: { $0.id == selectedTerminalID }),
           selectedTerminal.isReady || !selectedWorkspace.hasReadyTerminal {
            return
        }
        // Clear stale Mac selections and promote an active or Mac-focused
        // non-terminal before assigning a preferred terminal fallback.
        syncDefaultSurfaceForWorkspace()
        let workspaceID = selectedWorkspace.rpcWorkspaceID.rawValue
        if selectedMacSurfaceID != nil
            || simulatorStreamStore?.activeState(in: workspaceID) != nil
            || (browserStreamEvents as? BrowserStreamStore)?.activeState(in: workspaceID) != nil {
            return
        }
        selectedTerminalID = selectedWorkspace.preferredTerminal?.id
        if selectedTerminalID == nil {
            syncDefaultSurfaceForWorkspace()
        }
    }

    /// Re-evaluates the default surface after the workspace's panel lists
    /// finish loading. Panel discovery can arrive after the workspace is
    /// already selected, so this lets the shell promote the Mac-focused
    /// non-terminal, then fall back to the first available one.
    public func refreshWorkspaceSelection() {
        syncSelectedTerminalForWorkspace()
    }

    /// Promotes the Mac-focused non-terminal surface when no explicit terminal
    /// selection is active. Keeps the default-open workspace from landing on
    /// an empty terminal frame when only Mac surfaces or streamed panels exist.
    private func syncDefaultSurfaceForWorkspace() {
        guard let selectedWorkspace else { return }
        let workspaceID = selectedWorkspace.rpcWorkspaceID.rawValue
        if let selectedMacSurfaceID,
           !selectedWorkspace.surfaces.contains(where: { $0.id == selectedMacSurfaceID }) {
            self.selectedMacSurfaceID = nil
        }
        if simulatorStreamStore?.activeState(in: workspaceID) != nil {
            return
        }
        if let browserStore = browserStreamEvents as? BrowserStreamStore,
           browserStore.activeState(in: workspaceID) != nil {
            return
        }

        func activateStream(for surfaceID: MobileSurfacePreview.ID) -> Bool {
            if let simulatorPanelID = simulatorStreamStore?.panels(in: workspaceID)
                .first(where: { $0.panelID == surfaceID.rawValue })?.panelID {
                _ = simulatorStreamStore?.activate(panelID: simulatorPanelID, in: workspaceID)
                return true
            }
            if let browserStore = browserStreamEvents as? BrowserStreamStore,
               let browserPanelID = browserStore.panels(in: workspaceID)
                .first(where: { $0.panelID == surfaceID.rawValue })?.panelID {
                _ = browserStore.activate(panelID: browserPanelID, in: workspaceID)
                return true
            }
            return false
        }

        if let selectedMacSurfaceID {
            if activateStream(for: selectedMacSurfaceID) {
                return
            }
            if selectedWorkspace.surfaces.contains(where: { $0.id == selectedMacSurfaceID }) {
                return
            }
        }

        if let selectedSurface = selectedWorkspace.focusedNonTerminalSurface
            ?? selectedWorkspace.selectedMacSurface(id: nil) {
            if activateStream(for: selectedSurface.id) {
                return
            }
            selectedMacSurfaceID = selectedSurface.id
            return
        }

        if let simulatorPanelID = simulatorStreamStore?.panels(in: workspaceID).first?.panelID {
            _ = simulatorStreamStore?.activate(panelID: simulatorPanelID, in: workspaceID)
            return
        }
        if let browserStore = browserStreamEvents as? BrowserStreamStore,
           let browserPanelID = browserStore.panels(in: workspaceID).first?.panelID {
            _ = browserStore.activate(panelID: browserPanelID, in: workspaceID)
            return
        }
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

    private func createRemoteTerminal(in explicitWorkspaceID: MobileWorkspacePreview.ID? = nil) async {
        guard let client = remoteClient,
              let rowWorkspaceID = explicitWorkspaceID ?? selectedWorkspace?.id else {
            recordAppEvent(
                .terminalCreateFailed,
                correlationID: explicitWorkspaceID?.rawValue,
                failure: remoteClient == nil ? .offline : .endpointUnavailable
            )
            return
        }
        let diagnosticStartedAt = appDiagnosticNow()
        recordAppEvent(
            .terminalCreateStarted,
            correlationID: rowWorkspaceID.rawValue
        )
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
                  !Task.isCancelled else {
                recordAppEvent(
                    .terminalCreateFailed,
                    correlationID: rowWorkspaceID.rawValue,
                    startedAt: diagnosticStartedAt,
                    failure: .superseded
                )
                return
            }
            applyRemoteWorkspaceList(response, mergeExistingWorkspaces: true)
            if selectedWorkspaceID == rowWorkspaceID,
               let createdID = response.createdTerminalID {
                let createdTerminalID = MobileTerminalPreview.ID(rawValue: createdID)
                selectedTerminalID = createdTerminalID
                suppressTerminalAutoFocusOnNextAttach(for: createdTerminalID)
            }
            recordAppEvent(
                .terminalCreateSucceeded,
                correlationID: response.createdTerminalID ?? rowWorkspaceID.rawValue,
                startedAt: diagnosticStartedAt
            )
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else {
                recordAppEvent(
                    .terminalCreateFailed,
                    correlationID: rowWorkspaceID.rawValue,
                    startedAt: diagnosticStartedAt,
                    failure: .superseded
                )
                return
            }
            recordAppEvent(
                .terminalCreateFailed,
                correlationID: rowWorkspaceID.rawValue,
                startedAt: diagnosticStartedAt,
                failure: DiagnosticFailureKind.classify(error)
            )
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return }
            handleMacAvailabilityFailureIfCurrent(
                after: error,
                expectedClient: client,
                expectedGeneration: generation
            )
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
        _ = await sendRemoteTerminalInput(
            text,
            workspaceID: workspaceID,
            terminalID: terminalID
        )
    }

    /// Sends terminal input and stamps its eventual settlement outcome.
    private func sendRemoteTerminalInput(
        _ text: String,
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID,
        latencyBatchNumber: UInt64? = nil,
        sendStatusOperationID: UUID? = nil
    ) async {
        guard let client = remoteClient else {
            #if DEBUG
            mobileShellLog.info("skip remote terminal input remoteClient=0")
            #endif
            Self.stampTerminalInputSettlement(latencyBatchNumber, succeeded: false)
            finishRawTerminalSend(
                sendStatusOperationID,
                forTerminalID: terminalID.rawValue,
                succeeded: false
            )
            return
        }
        let generation = connectionGeneration
        if let terminalLaneCoordinator {
            let laneResult: MobileTerminalLaneCoordinator.InputResult
            if terminalInputRPCPipeline.hasAmbiguousFailure(
                surfaceID: terminalID.rawValue
            ) {
                // An earlier pipelined request for this surface failed without
                // a host response; the host may still apply it late. Refuse
                // the lane and stay on the ordered RPC path, which remains
                // correctly ordered with a late apply, until the next
                // connection-lifecycle reset.
                laneResult = .unavailable
            } else if terminalInputRPCPipeline.hasUnsettledRequests(
                surfaceID: terminalID.rawValue
            ) {
                if await terminalLaneCoordinator.isOutputReady(
                    surfaceID: terminalID.rawValue
                ) {
                    await terminalInputRPCPipeline.waitUntilAllSettled(
                        surfaceID: terminalID.rawValue
                    )
                    // The barrier can also resume via a connection-lifecycle
                    // clear() (sign-out, reconnect, new pairing attempt). The
                    // captured generation/client are then stale; fail closed
                    // instead of writing this chunk into a lane that may still
                    // belong to the previous connection.
                    guard generation == connectionGeneration,
                          client === remoteClient else {
                        Self.stampTerminalInputSettlement(
                            latencyBatchNumber,
                            succeeded: false
                        )
                        finishRawTerminalSend(
                            sendStatusOperationID,
                            forTerminalID: terminalID.rawValue,
                            succeeded: false
                        )
                        return
                    }
                    if terminalInputRPCPipeline.hasAmbiguousFailure(
                        surfaceID: terminalID.rawValue
                    ) {
                        // A request settled by the barrier just failed without
                        // a host response; same late-apply hazard as above.
                        laneResult = .unavailable
                    } else {
                        laneResult = await terminalLaneCoordinator.sendInput(
                            text,
                            surfaceID: terminalID.rawValue
                        )
                    }
                } else {
                    laneResult = .unavailable
                }
            } else {
                laneResult = await terminalLaneCoordinator.sendInput(
                    text,
                    surfaceID: terminalID.rawValue
                )
            }
            switch laneResult {
            case .sent:
                Self.stampTerminalInputSettlement(latencyBatchNumber, succeeded: true)
                finishRawTerminalSend(
                    sendStatusOperationID,
                    forTerminalID: terminalID.rawValue,
                    succeeded: true
                )
                return
            case .failed:
                mobileShellLog.error(
                    "independent terminal input failed surface=\(terminalID.rawValue, privacy: .public)"
                )
                Self.stampTerminalInputSettlement(latencyBatchNumber, succeeded: false)
                finishRawTerminalSend(
                    sendStatusOperationID,
                    forTerminalID: terminalID.rawValue,
                    succeeded: false
                )
                return
            case .unavailable:
                break
            }
        }
        let params = terminalInputParameters(
            text: text,
            workspaceID: workspaceID,
            terminalID: terminalID
        )
        if activeRoute?.kind == .iroh,
           supportedHostCapabilities.contains(
               Self.terminalInputOrderedCapability
           ) {
            do {
                try await terminalInputRPCPipeline.enqueue(
                    surfaceID: terminalID.rawValue,
                    makeRequest: {
                        try await client.sendRequestPipelined(
                            MobileCoreRPCClient.requestData(
                                method: "terminal.input",
                                params: params
                            )
                        )
                    },
                    settlementHandler: { [weak self, weak client] result in
                        switch result {
                        case let .success(responseData):
                            Self.stampTerminalInputSettlement(
                                latencyBatchNumber,
                                succeeded: true
                            )
                            self?.finishRawTerminalSend(
                                sendStatusOperationID,
                                forTerminalID: terminalID.rawValue,
                                succeeded: true
                            )
                            guard let self, let client else { return }
                            guard self.isCurrentRemoteOperation(
                                client: client,
                                generation: generation
                            ) else { return }
                            self.handleTerminalInputResponse(
                                responseData,
                                surfaceID: terminalID.rawValue
                            )
                        case let .failure(error):
                            Self.stampTerminalInputSettlement(
                                latencyBatchNumber,
                                succeeded: false
                            )
                            self?.finishRawTerminalSend(
                                sendStatusOperationID,
                                forTerminalID: terminalID.rawValue,
                                succeeded: false
                            )
                            guard let self, let client else { return }
                            self.handleTerminalInputFailure(
                                error,
                                client: client,
                                generation: generation
                            )
                        }
                    }
                )
                return
            } catch {
                // A generation change mid-enqueue (pipeline clear) surfaces as
                // CancellationError; that is a benign teardown, not an
                // operational failure, regardless of whether the caller also
                // rotated connectionGeneration.
                Self.stampTerminalInputSettlement(latencyBatchNumber, succeeded: false)
                finishRawTerminalSend(
                    sendStatusOperationID,
                    forTerminalID: terminalID.rawValue,
                    succeeded: false
                )
                if error is CancellationError { return }
                handleTerminalInputFailure(
                    error,
                    client: client,
                    generation: generation
                )
            }
            return
        }
        do {
            #if DEBUG
            mobileShellLog.debug("send remote terminal input byteCount=\(text.utf8.count, privacy: .public) workspace=\(workspaceID.rawValue, privacy: .private) terminal=\(terminalID.rawValue, privacy: .private)")
            #endif
            let responseData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "terminal.input",
                    params: params
                )
            )
            guard isCurrentRemoteOperation(client: client, generation: generation) else {
                Self.stampTerminalInputSettlement(latencyBatchNumber, succeeded: false)
                finishRawTerminalSend(
                    sendStatusOperationID,
                    forTerminalID: terminalID.rawValue,
                    succeeded: false
                )
                return
            }
            handleTerminalInputResponse(responseData, surfaceID: terminalID.rawValue)
            Self.stampTerminalInputSettlement(latencyBatchNumber, succeeded: true)
            finishRawTerminalSend(
                sendStatusOperationID,
                forTerminalID: terminalID.rawValue,
                succeeded: true
            )
        } catch {
            Self.stampTerminalInputSettlement(latencyBatchNumber, succeeded: false)
            finishRawTerminalSend(
                sendStatusOperationID,
                forTerminalID: terminalID.rawValue,
                succeeded: false
            )
            handleTerminalInputFailure(
                error,
                client: client,
                generation: generation
            )
        }
    }

    @inline(__always)
    private static func stampTerminalInputSettlement(
        _ latencyBatchNumber: UInt64?,
        succeeded: Bool
    ) {
        #if DEBUG
        guard let latencyBatchNumber else { return }
        MobileLatencyTrace.stamp(
            "in.settled",
            "n=\(latencyBatchNumber) ok=\(succeeded ? 1 : 0)"
        )
        #endif
    }

    private func terminalInputParameters(
        text: String,
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) -> [String: Any] {
        let key = viewportKey(
            workspaceID: workspaceID,
            terminalID: terminalID
        )
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
            if let generation = terminalViewportGeneration(
                for: terminalID.rawValue
            ) {
                params["viewport_generation"] = Int(clamping: generation)
            }
        }
        return params
    }

    private func handleTerminalInputFailure(
        _ error: any Error,
        client: MobileCoreRPCClient,
        generation: UUID
    ) {
        guard generation == connectionGeneration else { return }
        guard !disconnectForAuthorizationFailureIfNeeded(error) else { return }
        handleMacAvailabilityFailureIfCurrent(
            after: error,
            expectedClient: client,
            expectedGeneration: generation
        )
        applyOperationalError(error)
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
    /// followed by an optional submit key. Mirrors
    /// ``sendRemoteTerminalInput(_:workspaceID:terminalID:latencyBatchNumber:)``
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
                // Carry the dedicated-report generation so the Mac's fence can
                // reject this piggyback if it arrives after a newer report or
                // a clear (request tasks can reorder in transit).
                if let generation = terminalViewportGeneration(for: terminalID.rawValue) {
                    params["viewport_generation"] = Int(clamping: generation)
                }
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
            handleMacAvailabilityFailureIfCurrent(
                after: error,
                expectedClient: client,
                expectedGeneration: generation
            )
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
            recordAppEvent(
                .terminalImagePasteFailed,
                failure: .noRoute,
                count: data.count
            )
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
        recordAppEvent(
            .terminalImagePasteStarted,
            correlationID: terminalID.rawValue,
            count: data.count
        )
        guard !data.isEmpty else {
            recordAppEvent(
                .terminalImagePasteFailed,
                correlationID: terminalID.rawValue,
                failure: .protocolViolation
            )
            return false
        }
        guard remoteClient != nil else {
            recordAppEvent(
                .terminalImagePasteFailed,
                correlationID: terminalID.rawValue,
                failure: .noRoute,
                count: data.count
            )
            return false
        }
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
            recordAppEvent(
                .terminalImagePasteSucceeded,
                correlationID: terminalID.rawValue,
                count: data.count
            )
            return true
        } catch {
            if generation != connectionGeneration {
                recordAppEvent(
                    .terminalImagePasteFailed,
                    correlationID: terminalID.rawValue,
                    failure: .superseded,
                    count: data.count
                )
                return false
            }
            recordAppEvent(
                .terminalImagePasteFailed,
                correlationID: terminalID.rawValue,
                failure: DiagnosticFailureKind.classify(error),
                count: data.count
            )
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return false }
            handleMacAvailabilityFailureIfCurrent(
                after: error,
                expectedClient: client,
                expectedGeneration: generation
            )
            applyOperationalError(error)
            return false
        }
    }

    private var terminalEventStreamID: String {
        "ios-terminal-events-\(clientID)"
    }

    @discardableResult
    func unsubscribeEventStream(
        on client: MobileCoreRPCClient,
        streamID: String
    ) async -> Bool {
        guard let request = try? MobileCoreRPCClient.requestData(
            method: "mobile.events.unsubscribe",
            params: ["stream_id": streamID]
        ) else {
            return false
        }
        do {
            let response = try await client.sendRequest(request)
            guard let object = try JSONSerialization.jsonObject(with: response)
                    as? [String: Any],
                  object["stream_id"] as? String == streamID,
                  object["removed"] is Bool else {
                return false
            }
            // `removed == false` is also authoritative: the host proved no
            // registration exists for this stream ID.
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func unsubscribeTerminalEventStream(
        on client: MobileCoreRPCClient
    ) async -> Bool {
        await unsubscribeEventStream(on: client, streamID: terminalEventStreamID)
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

    private enum TerminalEventSubscriptionProbeResult {
        case active
        case missing
        case unsupported
        case failed
    }

    private func requestTerminalEventSubscription(
        client: MobileCoreRPCClient,
        reason: String,
        topics: [String],
        timeoutNanoseconds: UInt64? = nil
    ) async -> TerminalEventSubscriptionAck {
        let requestData: Data
        do {
            var params: [String: Any] = [
                "client_id": clientID,
                "stream_id": terminalEventStreamID,
                "topics": topics,
            ]
            // Negotiate screen-anchored render grids: the Mac then emits frames
            // anchored to the active area (with exact scrolled-row counts) so
            // this device owns a deep local scrollback and scrolls it locally.
            if usesScreenAnchoredRenderGrid, topics.contains("terminal.render_grid") {
                params["render_grid_anchor"] = MobileTerminalRenderGridFrame.Anchor.screen.rawValue
            }
            requestData = try MobileCoreRPCClient.requestData(
                method: "mobile.events.subscribe",
                params: params
            )
        } catch {
            mobileShellLog.error("subscribe payload encode failed: \(String(describing: error), privacy: .private)")
            return .failed
        }
        let responseData: Data
        do {
            responseData = try await client.sendRequest(
                requestData,
                timeoutNanoseconds: timeoutNanoseconds
            )
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
        recordAppEvent(
            reason == "start" ? .terminalStreamSubscribed : .terminalStreamResubscribed,
            count: topics.count
        )
        return .subscribed(alreadySubscribed: response?.alreadySubscribed)
    }

    private func resolveTerminalOutputTransport(
        client: MobileCoreRPCClient,
        initialHostStatus: MobileHostStatusResponse? = nil
    ) async -> TerminalOutputTransport {
        let generation = connectionGeneration
        do {
            let payload: MobileHostStatusResponse
            if let initialHostStatus {
                payload = initialHostStatus
            } else {
                let data = try await client.sendRequest(
                    MobileCoreRPCClient.requestData(method: "mobile.host.status", params: [:]),
                    timeoutNanoseconds: Self.terminalOutputCapabilityTimeoutNanoseconds
                )
                guard let decoded = try? MobileHostStatusResponse.decode(data) else {
                    guard let fallback = Self.guardedFallbackTerminalOutputTransport(
                        learnedCapabilities: supportedHostCapabilities,
                        isCurrentClient: isCurrentRemoteConnection(
                            client: client,
                            generation: generation
                        )
                    ) else {
                        return .rawBytes
                    }
                    terminalOutputTransport = fallback
                    // Preserve learned capabilities during transient status decode failures.
                    scheduleHostIdentityAdoptionIfNeeded(client: client)
                    return fallback
                }
                payload = decoded
            }
            // The status round-trip suspends, and a reconnect/new pairing can
            // install a different `remoteClient` (and a fresh `activeTicket`)
            // in the meantime. A stale response must not mutate the current
            // connection's transport state, and above all must not adopt the
            // OLD Mac's identity onto the NEW connection's empty-id ticket
            // (which would persist the wrong paired-Mac record). The stale
            // listener task tears itself down via its own `remoteClient`
            // guards; returning the fallback here is inert.
            guard isCurrentRemoteConnection(
                client: client,
                generation: generation
            ) else {
                return .rawBytes
            }
            supportedHostCapabilities = Set(payload.capabilities)
            phonePushMacStatus = payload.phonePush
            restartActiveMobileBrowserStreams()
            restartActiveMobileSimulatorStreams()
            refreshVisibleMobileBrowserPanels()
            prepareTerminalThemeRevisionAuthority(
                macInstanceTag: payload.macInstanceTag, producerEpoch: payload.terminalThemeRevisionEpoch,
                connectionID: connectionGeneration.uuidString
            )
            // Adopt the Mac's resolved terminal theme. Older Macs omit the
            // field (`payload.theme == nil`), which the store resolves to the
            // built-in Monokai default. This funnels through the same
            // the selected surface's authoritative state and bumps the live
            // update generation only on a real change.
            applyTerminalTheme(payload.theme)
            updateForegroundWorkspaceActionCapabilities()
            refreshMacUpdateHint(capabilities: Set(payload.capabilities), statusMacAppVersion: payload.macAppVersion, macDeviceID: payload.macDeviceID ?? activeTicket?.macDeviceID)
            await applyHostReportedIdentity(
                client: client,
                deviceID: payload.macDeviceID,
                displayName: payload.macDisplayName,
                instanceTag: payload.macInstanceTag,
                clientNamespace: payload.macClientNamespace,
                macAppVersion: payload.macAppVersion
            )
            guard isCurrentRemoteConnection(
                client: client,
                generation: generation
            ) else {
                return .rawBytes
            }
            // A decoded status can still be identity-free: the probe's token
            // attach is best-effort, and the host withholds identity from an
            // unverified caller. If the v2 QR ticket is still anonymous after
            // applying, run the dedicated recovery (it re-asks the token
            // provider and no-ops once an identity is adopted).
            scheduleHostIdentityAdoptionIfNeeded(client: client)
            let transport = Self.resolvedTerminalOutputTransport(
                capabilities: Set(payload.capabilities),
                terminalFidelity: payload.terminalFidelity
            )
            terminalOutputTransport = transport
            reconcileTerminalLanesForOutputTransport()
            MobileDebugLog.anchormux("sync.transport=\(transport.debugName)")
            upgradePendingColdTerminalReplaysIfNeeded()
            return transport
        } catch {
            guard let fallback = Self.guardedFallbackTerminalOutputTransport(
                learnedCapabilities: supportedHostCapabilities,
                isCurrentClient: isCurrentRemoteConnection(
                    client: client,
                    generation: generation
                )
            ) else {
                return .rawBytes
            }
            terminalOutputTransport = fallback
            reconcileTerminalLanesForOutputTransport()
            // Preserve learned capabilities during transient reconnect probe failures.
            // The probe is best-effort for the terminal transport, but a
            // freshly QR-paired Mac still needs its identity recovered, with
            // a real timeout instead of the probe's 750ms.
            scheduleHostIdentityAdoptionIfNeeded(client: client)
            MobileDebugLog.anchormux(
                "sync.transport=\(fallback.debugName) reason=status_failed"
            )
            return fallback
        }
    }

    private func refreshTerminalEventSubscription(reason: String) {
        guard let client = remoteClient, connectionState == .connected else { return }
        guard terminalSubscriptionHandoffFences[ObjectIdentifier(client)]
                == nil else {
            return
        }
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

    func startTerminalRefreshPolling(
        initialHostStatus: MobileHostStatusResponse? = nil,
        subscriptionReadiness: MobileTerminalEventSubscriptionReadiness? = nil,
        recoversConnectionOnSubscriptionFailure: Bool = true
    ) {
        guard let client = remoteClient,
              runtime?.supportsServerPushEvents ?? true,
              terminalEventListenerTask == nil else {
            if let subscriptionReadiness {
                Task { await subscriptionReadiness.resolve(false) }
            }
            return
        }
        let clientID = ObjectIdentifier(client)
        if terminalSubscriptionHandoffFences[clientID] != nil {
            let focusedConnection = foregroundMacDeviceID.flatMap {
                connections[$0]
            }
            guard focusedConnection?.client === client,
                  focusedConnection.map({
                      !focusedHandoffPreparedGenerations.contains($0.generation)
                  }) == true else {
                if let subscriptionReadiness {
                    Task { await subscriptionReadiness.resolve(false) }
                }
                return
            }
            terminalSubscriptionHandoffFences[clientID] = nil
        }
        let listenerID = UUID()
        let listenerConnectionGeneration = connectionGeneration
        terminalEventListenerID = listenerID
        markMacConnectionHealthy()
        // Arm the liveness watchdog for this subscription generation. Done only
        // inside the push-events path (after the guard above) so scripted
        // transport tests, which set `supportsServerPushEvents = false`, never
        // schedule speculative re-subscribes. A fresh subscription gets a full
        // silence window before it can be judged dead.
        startRenderGridLivenessWatchdog(listenerID: listenerID)
        terminalEventListenerTask = Task { @MainActor [weak self] in
            guard self != nil else {
                await subscriptionReadiness?.resolve(false)
                return
            }
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

            let outputTransport = await self?.resolveTerminalOutputTransport(
                client: client,
                initialHostStatus: initialHostStatus
            ) ?? .rawBytes
            guard !Task.isCancelled else {
                await subscriptionReadiness?.resolve(false)
                return
            }
            self?.scheduleForegroundNotificationFeedRefresh(client: client)
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
            guard self != nil else {
                await subscriptionReadiness?.resolve(false)
                return
            }
            self?.beginTerminalEventSubscriptionStart(
                client: client,
                listenerID: listenerID,
                connectionGeneration: listenerConnectionGeneration,
                topics: topics,
                transport: outputTransport,
                subscriptionReadiness: subscriptionReadiness,
                recoversConnectionOnFailure:
                    recoversConnectionOnSubscriptionFailure
            )
            // Keep the listener alive without keeping the shell store alive.
            for await event in stream {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard self.isCurrentRemoteOperation(
                    client: client,
                    generation: listenerConnectionGeneration
                ) else {
                    return
                }
                // Any yielded envelope proves the transport is still pushing, so
                // it resets the liveness window (not just render_grid events).
                self.cancelTerminalInputAckResubscribeRetry()
                self.recordTerminalEventStreamLiveness()
                self.markMacConnectionHealthy()
                if event.topic == "workspace.updated" {
                    self.scheduleWorkspaceListRefreshFromEvent()
                    self.refreshVisibleMobileBrowserPanels()
                } else if event.topic == "mobile.sync.delta" {
                    self.handleStateSyncDeltaEvent(event)
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
                } else if event.topic == "notification.feed.changed",
                          let macDeviceID = self.normalizedForegroundNotificationFeedMacIDForEvent() {
                    self.handleNotificationFeedChangedEvent(
                        event,
                        macDeviceID: macDeviceID,
                        client: client,
                        displayName: self.notificationFeedDisplayNameForForeground(
                            macDeviceID: macDeviceID
                        )
                    )
                } else if event.topic == "phone_push.status.changed" {
                    await self.refreshPhonePushStatus(
                        client: client,
                        generation: self.connectionGeneration
                    )
                } else if event.topic == "caffeine.status.changed" {
                    self.handleCaffeineStatusEvent(
                        event,
                        client: client,
                        generation: listenerConnectionGeneration
                    )
                } else if event.topic == "browser.frame" {
                    self.handleMobileBrowserFrameEvent(event)
                } else if event.topic == "browser.state" {
                    self.handleMobileBrowserStateEvent(event)
                } else if event.topic == "browser.closed" {
                    self.handleMobileBrowserClosedEvent(event)
                } else if event.topic == "browser.dialog" {
                    self.handleMobileBrowserDialogEvent(event)
                } else if event.topic == "browser.dialog.resolved" {
                    self.handleMobileBrowserDialogResolvedEvent(event)
                } else if event.topic == "simulator.frame" {
                    self.handleMobileSimulatorFrameEvent(event)
                } else if event.topic == "simulator.state" {
                    self.handleMobileSimulatorStateEvent(event)
                } else if event.topic == "simulator.closed" {
                    self.handleMobileSimulatorClosedEvent(event)
                }
            }
            guard let self else { return }
            let readinessSucceeded =
                await subscriptionReadiness?.hasSucceeded() == true
            let recoversEndedStream =
                recoversConnectionOnSubscriptionFailure
                    || readinessSucceeded
            self.handleTerminalEventStreamEnded(
                listenerID: listenerID,
                client: client,
                recoversConnectionOnFailure: recoversEndedStream
            )
        }
    }

    private func refreshPhonePushStatus(
        client: MobileCoreRPCClient,
        generation: UUID
    ) async {
        let exchange: (response: Data, hostStatusResponse: Data)
        do {
            exchange = try await client.sendRequestAndAuthenticatedHostStatus(
                MobileCoreRPCClient.requestData(
                    method: "phone_push.status.get",
                    params: [:]
                ),
                timeoutNanoseconds: Self.terminalOutputCapabilityTimeoutNanoseconds,
                hostStatusTimeoutNanoseconds: {
                    Self.terminalOutputCapabilityTimeoutNanoseconds
                }
            )
        } catch {
            guard isCurrentRemoteConnection(
                client: client,
                generation: generation
            ) else { return }
            // This status probe is authenticated: a definitive authorization
            // failure here means the session itself is revoked or mismatched,
            // not merely that push readiness is unknown. Route it to the
            // shared reauth disconnect instead of staying connected with a
            // silently cleared readiness.
            guard !disconnectForAuthorizationFailureIfNeeded(error) else {
                return
            }
            phonePushMacStatus = nil
            return
        }
        guard isCurrentRemoteConnection(
            client: client,
            generation: generation
        ) else { return }
        guard let status = try? MobileHostStatusResponse.decode(
            exchange.hostStatusResponse
        ) else {
            phonePushMacStatus = nil
            return
        }
        phonePushMacStatus = status.phonePush
    }

    /// Applies one or more Mac-owned phone-forwarding settings over the current
    /// authenticated attach channel, then reads the authoritative status back.
    ///
    /// The mutation fails closed when the Mac is unavailable, predates the
    /// capability, rejects the caller, or the connection changes mid-flight.
    /// Local UI never writes a speculative Mac value into this store.
    @discardableResult
    public func updatePhonePushSettings(
        forwardingEnabled: Bool? = nil,
        mode: MobileHostPhonePushStatus.Mode? = nil,
        hideContent: Bool? = nil
    ) async -> Bool {
        guard supportsPhonePushSettings,
              let client = remoteClient,
              forwardingEnabled != nil || mode != nil || hideContent != nil
        else { return false }

        var params: [String: Any] = [:]
        if let forwardingEnabled {
            params["forwarding_enabled"] = forwardingEnabled
        }
        if let mode {
            params["mode"] = mode.rawValue
        }
        if let hideContent {
            params["hide_content"] = hideContent
        }

        let generation = connectionGeneration
        do {
            let exchange = try await client.sendRequestAndAuthenticatedHostStatus(
                MobileCoreRPCClient.requestData(
                    method: "phone_push.settings.update",
                    params: params
                ),
                hostStatusTimeoutNanoseconds: {
                    Self.terminalOutputCapabilityTimeoutNanoseconds
                }
            )
            let status = try MobileHostStatusResponse.decode(
                exchange.hostStatusResponse
            )
            guard isCurrentRemoteConnection(
                client: client,
                generation: generation
            ) else { return false }
            phonePushMacStatus = status.phonePush
            return true
        } catch {
            guard generation == connectionGeneration else { return false }
            guard !disconnectForAuthorizationFailureIfNeeded(error) else {
                return false
            }
            handleMacAvailabilityFailureIfCurrent(
                after: error,
                expectedClient: client,
                expectedGeneration: generation
            )
            return false
        }
    }

    /// Requests a test alert through the Mac's real durable queue and returns
    /// only the furthest stage the synchronous RPC can prove.
    public func sendPhonePushTest() async -> MobilePhonePushTestStage {
        guard supportsPhonePushTest, let client = remoteClient else {
            return .unavailable
        }
        let generation = connectionGeneration
        do {
            let data = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "phone_push.test",
                    params: [:]
                )
            )
            guard isCurrentRemoteConnection(
                client: client,
                generation: generation
            ), let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let rawStage = object["stage"] as? String,
            let stage = MobilePhonePushTestStage(rawValue: rawStage)
            else { return .unavailable }
            return stage
        } catch {
            guard generation == connectionGeneration else {
                return .unavailable
            }
            guard !disconnectForAuthorizationFailureIfNeeded(error) else {
                return .unavailable
            }
            handleMacAvailabilityFailureIfCurrent(
                after: error,
                expectedClient: client,
                expectedGeneration: generation
            )
            return .unavailable
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
        connectionGeneration: UUID,
        topics: [String],
        transport: TerminalOutputTransport,
        subscriptionReadiness: MobileTerminalEventSubscriptionReadiness? = nil,
        recoversConnectionOnFailure: Bool
    ) {
        guard terminalEventListenerID == listenerID else {
            if let subscriptionReadiness {
                Task { await subscriptionReadiness.resolve(false) }
            }
            return
        }
        guard terminalSubscriptionHandoffFences[ObjectIdentifier(client)]
                == nil else {
            if let subscriptionReadiness {
                Task { await subscriptionReadiness.resolve(false) }
            }
            return
        }
        terminalSubscriptionStartTask?.cancel()
        terminalSubscriptionStartTask = Task { @MainActor [weak self] in
            var didSubscribe = false
            defer {
                if let subscriptionReadiness {
                    Task {
                        await subscriptionReadiness.resolve(didSubscribe)
                    }
                }
            }
            let ack = await self?.requestTerminalEventSubscription(
                client: client,
                reason: "start",
                topics: topics
            ) ?? .failed
            guard let self else { return }
            guard !Task.isCancelled,
                  self.terminalEventListenerID == listenerID,
                  self.isCurrentRemoteOperation(
                      client: client,
                      generation: connectionGeneration
                  ) else {
                return
            }
            self.terminalSubscriptionStartTask = nil
            guard ack.isSubscribed else {
                MobileDebugLog.anchormux("sync.subscribe_failed reason=start")
                self.diagnosticLog?.record(DiagnosticEvent(.error))
                if recoversConnectionOnFailure {
                    self.recoverDeadConnection(
                        trigger: .subscriptionStartFailed,
                        expectedClient: client
                    )
                }
                return
            }
            // Keep every MainActor mutation before publishing readiness. The
            // cross-actor readiness hop can admit a cancellation or newer
            // listener, and a stale acknowledgement must never mutate that
            // replacement connection after it resumes.
            guard self.recordUsableTerminalSubscription(
                client: client,
                connectionGeneration: connectionGeneration,
                listenerID: listenerID
            ) else {
                return
            }
            didSubscribe = true
            MobileDebugLog.anchormux("sync.subscribe_ok topics=\(topics.count) transport=\(transport)")
            // Negotiate state sync v2 only from the subscription
            // ACKNOWLEDGEMENT: the ack proves the Mac registered this
            // connection for `mobile.sync.delta`, so a fetch snapshot taken
            // now cannot miss a change emitted between fetch and
            // registration. (A fetch racing the handshake could snapshot rev
            // N, miss N+1 emitted before the server registered us, and stay
            // stale until the next unrelated change.)
            self.beginStateSyncNegotiation(client: client)
            self.scheduleNotificationReconcile(client: client)
            // Promotion suppresses recovery only for its initial handoff
            // handshake. Publish success after the listener state is committed
            // so every later stream closure resumes ordinary focused recovery.
            await subscriptionReadiness?.resolve(true)
        }
    }

    private func handleTerminalEventStreamEnded(
        listenerID: UUID,
        client: MobileCoreRPCClient,
        recoversConnectionOnFailure: Bool
    ) {
        guard !Task.isCancelled,
              terminalEventListenerID == listenerID,
              remoteClient === client,
              connectionState == .connected else {
            return
        }
        recordAppEvent(.terminalStreamEnded, failure: .connectionClosed)
        guard recoversConnectionOnFailure else {
            terminalSubscriptionStartTask?.cancel()
            terminalSubscriptionStartTask = nil
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
            recoverDeadConnection(
                trigger: .subscriptionStartFailed,
                expectedClient: client
            )
            return
        }
        mobileShellLog.info("terminal event stream ended, redialing stored Mac")
        MobileDebugLog.anchormux("sync.stream_ended redialing stored Mac")
        diagnosticLog?.record(DiagnosticEvent(.streamEnded))
        recoverDeadConnection(trigger: .eventStreamEnded, expectedClient: client)
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
        renderGridLivenessConsecutiveProbeFailures = 0
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
        renderGridLivenessConsecutiveProbeFailures = 0
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
    /// down + re-subscribe + replay (via the existing resync path) after two
    /// consecutive probe failures with no intervening evidence of liveness.
    ///
    /// The probe step exists because silence is ambiguous: a healthy idle
    /// terminal emits nothing (the Mac dedupes unchanged render-grid frames by
    /// row signature and stateSeq), which is indistinguishable by wall clock
    /// from the half-dead transport this watchdog was built to catch. Treating
    /// silence alone as death made the watchdog tear down and full-grid-replay
    /// every healthy idle subscription every ~10.5s, forever (the 2026-06-10
    /// Release-sim bisect finding).
    ///
    /// The read-only `mobile.events.probe` checks the SAME stream id: a
    /// completed response proves the control channel is alive and reports
    /// whether the host still owns the registration without replacing it or
    /// churning producer demand. A missing registration is repaired with one
    /// subscribe and replay; an older host that lacks the probe verb falls
    /// back to the former idempotent subscribe behavior.
    private func checkRenderGridLiveness(listenerID: UUID) {
        guard renderGridLivenessListenerID == listenerID else { return }
        guard let client = remoteClient, connectionState == .connected else { return }
        guard terminalSubscriptionHandoffFences[ObjectIdentifier(client)]
                == nil else {
            return
        }
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
                    self.repairLostTerminalEventSubscription(
                        reason: "liveness_probe_repaired"
                    )
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
            self.renderGridLivenessConsecutiveProbeFailures += 1
            let probeFailures = self.renderGridLivenessConsecutiveProbeFailures
            guard probeFailures >= Self.renderGridLivenessFailuresBeforeRecovery else {
                MobileDebugLog.anchormux(
                    "sync.liveness probe_failed awaiting_confirmation failures=\(probeFailures) silentMs=\(silentMs)"
                )
                mobileShellLog.info(
                    "render-grid subscription probe failed \(probeFailures, privacy: .public)x after \(silentMs, privacy: .public)ms of silence; awaiting confirmation"
                )
                return
            }
            self.renderGridLivenessConsecutiveProbeFailures = 0
            MobileDebugLog.anchormux("sync.liveness re-subscribe silentMs=\(silentMs)")
            self.recordAppEvent(
                .terminalRenderLagDetected,
                failure: .timedOut,
                count: probeFailures
            )
            self.diagnosticLog?.record(DiagnosticEvent(.livenessResubscribe, ms: UInt32(clamping: silentMs)))
            mobileShellLog.info("render-grid stream silent for \(silentMs, privacy: .public)ms and subscription probe failed, re-subscribing")
            // The bounded probe proved this exact client dead. Hand the session
            // to the single recovery owner instead of rebuilding another listener
            // on the same stale shell.
            self.recoverDeadConnection(trigger: .liveness, expectedClient: client)
        }
    }

    /// Bounded positive-liveness probe: inspect the existing event
    /// registration without mutating it, repairing it only when missing.
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
            guard let self else { return TerminalEventSubscriptionAck.failed }
            switch await self.requestTerminalEventSubscriptionProbe(
                client: client,
                timeoutNanoseconds: timeoutNanoseconds
            ) {
            case .active:
                return .subscribed(alreadySubscribed: true)
            case .missing, .unsupported:
                return await self.requestTerminalEventSubscription(
                    client: client,
                    reason: "liveness_probe_repair",
                    topics: topics,
                    timeoutNanoseconds: timeoutNanoseconds
                )
            case .failed:
                return .failed
            }
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

    private func requestTerminalEventSubscriptionProbe(
        client: MobileCoreRPCClient,
        timeoutNanoseconds: UInt64
    ) async -> TerminalEventSubscriptionProbeResult {
        let requestData: Data
        do {
            requestData = try MobileCoreRPCClient.requestData(
                method: "mobile.events.probe",
                params: [
                    "client_id": clientID,
                    "stream_id": terminalEventStreamID,
                ]
            )
        } catch {
            return .failed
        }
        do {
            let data = try await client.sendRequest(
                requestData,
                timeoutNanoseconds: timeoutNanoseconds
            )
            guard let object = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  object["stream_id"] as? String == terminalEventStreamID,
                  let subscribed = object["subscribed"] as? Bool else {
                return .failed
            }
            return subscribed ? .active : .missing
        } catch MobileShellConnectionError.rpcError(let code, _)
            where code == "method_not_found" {
            return .unsupported
        } catch {
            if remoteClient === client {
                _ = disconnectForAuthorizationFailureIfNeeded(error)
            }
            return .failed
        }
    }

    func resyncTerminalOutput(
        reason: String,
        restartEventStream: Bool,
        surfaceIDs requestedSurfaceIDs: [String]? = nil
    ) {
        guard remoteClient != nil, connectionState == .connected else { return }
        refreshTerminalOutputSubscription(reason: reason, restartEventStream: restartEventStream)

        let surfaceIDs = requestedSurfaceIDs ?? Array(terminalByteContinuationsBySurfaceID.keys)
        MobileDebugLog.anchormux(
            "sync.resync reason=\(reason) restart=\(restartEventStream) surfaces=\(surfaceIDs.count)"
        )
        for surfaceID in surfaceIDs {
            requestAuthoritativeTerminalResync(surfaceID: surfaceID, reason: reason)
        }
    }

    private func refreshTerminalOutputSubscription(reason: String, restartEventStream: Bool) {
        if restartEventStream {
            stopTerminalRefreshPolling()
            startTerminalRefreshPolling()
        } else if terminalEventListenerTask == nil {
            startTerminalRefreshPolling()
        } else {
            refreshTerminalEventSubscription(reason: reason)
        }
    }

    private func handleTerminalInputResponse(_ data: Data, surfaceID: String) {
        guard hasTerminalOutputSink(surfaceID: surfaceID),
              let payload = try? MobileTerminalInputResponse.decode(data),
              let remoteSeq = payload.terminalSeq else {
            return
        }
        #if DEBUG
        MobileLatencyTrace.stamp(
            "in.resp",
            "s=\(surfaceID.prefix(8).lowercased()) ack_seq=\(remoteSeq)"
        )
        #endif
        let localSeq = deliveredTerminalByteEndSeqBySurfaceID[surfaceID] ?? 0
        guard remoteSeq > localSeq else { return }
        let canRenderGridAdvancePendingSeq = terminalOutputTransport == .renderGrid
            || (terminalOutputTransport == .hybrid && terminalActiveScreenBySurfaceID[surfaceID] == .alternate)
        if canRenderGridAdvancePendingSeq, terminalEventListenerTask != nil {
            let previousPendingSeq = pendingTerminalByteEndSeqBySurfaceID[surfaceID]
            let targetSeq = max(remoteSeq, pendingTerminalByteEndSeqBySurfaceID[surfaceID] ?? 0)
            if let previousPendingSeq {
                guard targetSeq > previousPendingSeq else {
                    if pendingTerminalInputDroppedRenderGridSurfaceIDs.contains(surfaceID) {
                        MobileDebugLog.anchormux(
                            "sync.input_seq_replay_after_drop surface=\(surfaceID) local=\(localSeq) pending=\(targetSeq) remote=\(remoteSeq)"
                        )
                        requestTerminalReplayAfterDroppedRenderGrid(surfaceID: surfaceID, source: "input_ack")
                    }
                    return
                }
            }
            if previousPendingSeq == nil {
                // A fresh catch-up episode gets a fresh replay retry budget:
                // the counter is shared with barrier replay failures, and a
                // prior episode that succeeded only after burning retries
                // must not suppress the repair replay this episode may need.
                terminalReplayFailureRetryCountsBySurfaceID.removeValue(forKey: surfaceID)
            }
            pendingTerminalByteEndSeqBySurfaceID[surfaceID] = targetSeq
            MobileDebugLog.anchormux("sync.input_seq_wait surface=\(surfaceID) local=\(localSeq) pending=\(targetSeq) remote=\(remoteSeq)")
            let now = runtime?.now() ?? Date()
            if lastTerminalEventAt.map({
                now.timeIntervalSince($0) >= Self.terminalInputAckResubscribeSilenceThreshold
            }) ?? true {
                cancelTerminalInputAckResubscribeRetry()
                refreshTerminalEventSubscription(reason: "input_seq_wait")
            } else if let lastTerminalEventAt {
                scheduleTerminalInputAckResubscribeRetry(
                    surfaceID: surfaceID,
                    pendingSeq: targetSeq,
                    lastTerminalEventAt: lastTerminalEventAt,
                    now: now
                )
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

    /// Coalesces the freshness-guard follow-up into one cancellable delay.
    private func scheduleTerminalInputAckResubscribeRetry(
        surfaceID: String,
        pendingSeq: UInt64,
        lastTerminalEventAt: Date,
        now: Date
    ) {
        cancelTerminalInputAckResubscribeRetry()
        guard let listenerID = terminalEventListenerID,
              terminalEventListenerTask != nil else {
            return
        }
        let elapsed = max(0, now.timeIntervalSince(lastTerminalEventAt))
        let delay = max(
            0,
            Self.terminalInputAckResubscribeSilenceThreshold - elapsed
        )
        let taskID = UUID()
        terminalInputAckResubscribeRetryTaskID = taskID
        terminalInputAckResubscribeRetrySurfaceID = surfaceID
        let clock = terminalInputAckResubscribeClock
        terminalInputAckResubscribeRetryTask = Task { @MainActor [weak self] in
            try? await clock.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            guard self.terminalInputAckResubscribeRetryTaskID == taskID else { return }
            self.terminalInputAckResubscribeRetryTask = nil
            self.terminalInputAckResubscribeRetryTaskID = nil
            self.terminalInputAckResubscribeRetrySurfaceID = nil
            guard self.connectionState == .connected,
                  let client = self.remoteClient,
                  self.terminalEventListenerID == listenerID,
                  self.terminalEventListenerTask != nil,
                  self.lastTerminalEventAt == lastTerminalEventAt,
                  self.pendingTerminalByteEndSeqBySurfaceID[surfaceID] == pendingSeq,
                  (self.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] ?? 0) < pendingSeq
            else {
                return
            }
            let ack = await self.requestTerminalEventSubscription(
                client: client,
                reason: "input_seq_wait_retry",
                topics: self.terminalOutputTransport.eventTopics
            )
            guard !Task.isCancelled,
                  self.connectionState == .connected,
                  self.remoteClient === client,
                  self.terminalEventListenerID == listenerID,
                  self.terminalEventListenerTask != nil,
                  self.lastTerminalEventAt == lastTerminalEventAt,
                  self.pendingTerminalByteEndSeqBySurfaceID[surfaceID] == pendingSeq,
                  (self.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] ?? 0) < pendingSeq,
                  case .subscribed(let alreadySubscribed) = ack
            else {
                return
            }
            if alreadySubscribed == false {
                self.repairLostTerminalEventSubscription(
                    reason: "input_seq_wait_retry"
                )
            } else {
                self.requestAuthoritativeTerminalResync(
                    surfaceID: surfaceID,
                    reason: "input_seq_wait_retry"
                )
            }
        }
    }

    /// Repairs every collection carried by a host registration that was absent.
    private func repairLostTerminalEventSubscription(reason: String) {
        for surfaceID in terminalByteContinuationsBySurfaceID.keys {
            requestAuthoritativeTerminalResync(
                surfaceID: surfaceID,
                reason: reason
            )
        }
        // The same registration carries `workspace.updated` and
        // `mobile.sync.delta`, so list changes emitted during the gap were
        // missed too; repair through the mode-appropriate authoritative path.
        repairMissedEventWindow()
    }

    /// Cancels the one-shot ACK retry, optionally only for its owning surface.
    func cancelTerminalInputAckResubscribeRetry(surfaceID: String? = nil) {
        if let surfaceID,
           terminalInputAckResubscribeRetrySurfaceID != surfaceID {
            return
        }
        terminalInputAckResubscribeRetryTask?.cancel()
        terminalInputAckResubscribeRetryTask = nil
        terminalInputAckResubscribeRetryTaskID = nil
        terminalInputAckResubscribeRetrySurfaceID = nil
    }

    private static func terminalSnapshotReplacementBytes(_ snapshotBytes: Data) -> Data {
        var bytes = Data("\u{1B}c\u{1B}[H\u{1B}[2J\u{1B}[3J".utf8)
        bytes.append(snapshotBytes)
        return bytes
    }

    @discardableResult
    private func registerTerminalOutput(
        surfaceID: String,
        continuation: AsyncStream<MobileTerminalOutputChunk>.Continuation,
        ownerID: UUID?
    ) -> UUID {
        // A replacement consumer can inherit an active replay barrier from
        // the stream it is replacing. Keep that barrier's existing deadline
        // alive, but do not recreate a watchdog after replay admission
        // intentionally cancelled it. The admitted request owns completion;
        // consumer churn must not restart its barrier deadline indefinitely.
        if let barrierToken = terminalReplayBarrierTokensBySurfaceID[surfaceID] {
            if terminalReplayBarrierTokensInFlightBySurfaceID[surfaceID]
                != barrierToken {
                armTerminalReplayBarrierWatchdog(
                    surfaceID: surfaceID,
                    token: barrierToken
                )
            }
        } else {
            cancelTerminalReplayBarrierWatchdog(surfaceID: surfaceID)
        }
        let streamToken = UUID()
        terminalByteContinuationsBySurfaceID[surfaceID] = continuation
        terminalOutputStreamTokensBySurfaceID[surfaceID] = streamToken
        terminalOutputConsumerOwnerIDsBySurfaceID[surfaceID] = ownerID
        terminalOutputQueuesBySurfaceID[surfaceID] = TerminalOutputDeliveryQueue()
        deliveredTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        terminalPreBarrierDeliveredEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        terminalRenderGridHistoryContinuityBySurfaceID.removeValue(forKey: surfaceID)
        diagnosedTerminalOutputSurfaceIDs.remove(surfaceID)
        terminalRenderGridBaselineReplayRequestCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalRenderGridBaselineReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalAlternateRenderGridBaselineSurfaceIDs.remove(surfaceID)
        terminalFullReplacementSeqBySurfaceID.removeValue(forKey: surfaceID)
        terminalFullReplacementGenerationBySurfaceID.removeValue(forKey: surfaceID)
        cancelTerminalInputAckResubscribeRetry(surfaceID: surfaceID)
        pendingTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        pendingTerminalInputDroppedRenderGridSurfaceIDs.remove(surfaceID)
        recordAppEvent(
            .terminalMounted,
            correlationID: surfaceID
        )
        #if DEBUG
        mobileShellLog.info("CMUX_REPLAY register sink surface=\(surfaceID, privacy: .public) connected=\(self.connectionState == .connected, privacy: .public) hasClient=\(self.remoteClient != nil, privacy: .public) workspaceCount=\(self.workspaces.count, privacy: .public)")
        startLatencyProbeIfReady()
        #endif
        requestColdAttachTerminalReplay(surfaceID: surfaceID)
        ensureTerminalLane(surfaceID: surfaceID)
        return streamToken
    }

    private func unregisterTerminalOutput(surfaceID: String, streamToken: UUID) {
        guard terminalOutputStreamTokensBySurfaceID[surfaceID] == streamToken else { return }
        terminalLaneOutputReadySurfaceIDs.remove(surfaceID)
        if let terminalLaneCoordinator {
            Task { await terminalLaneCoordinator.deactivate(surfaceID: surfaceID) }
        }
        cancelTerminalReplayBarrierWatchdog(surfaceID: surfaceID)
        cancelTerminalReplayInFlight(surfaceID: surfaceID)
        terminalColdReplayNeedsBarrierUpgradeSurfaceIDs.remove(surfaceID)
        terminalByteContinuationsBySurfaceID.removeValue(forKey: surfaceID)
        terminalOutputStreamTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalOutputQueuesBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierAckStreamTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierDroppedOutputSurfaceIDs.remove(surfaceID)
        terminalReplayBarrierDroppedOutputCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierAckCoveredDroppedOutputCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayFailureRetryCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierFollowUpCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalColdAttachReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalScrollQueueTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalScrollQueuesBySurfaceID.removeValue(forKey: surfaceID)
        terminalScrollbackPrefetchStatesBySurfaceID.removeValue(forKey: surfaceID)
        effectiveViewportSizesBySurfaceID.removeValue(forKey: surfaceID); reportedTerminalViewportSizesBySurfaceID.removeValue(forKey: surfaceID)
        terminalViewportReplayBarrierPendingAckTokensBySurfaceID.removeValue(forKey: surfaceID)
        deliveredTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        terminalPreBarrierDeliveredEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        terminalRenderGridBaselineReplayRequestCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalRenderGridBaselineReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalAlternateRenderGridBaselineSurfaceIDs.remove(surfaceID)
        terminalFullReplacementSeqBySurfaceID.removeValue(forKey: surfaceID)
        terminalFullReplacementGenerationBySurfaceID.removeValue(forKey: surfaceID)
        cancelTerminalInputAckResubscribeRetry(surfaceID: surfaceID)
        pendingTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        pendingTerminalInputDroppedRenderGridSurfaceIDs.remove(surfaceID)
        terminalActiveScreenBySurfaceID.removeValue(forKey: surfaceID)
        terminalRenderGridHistoryContinuityBySurfaceID.removeValue(forKey: surfaceID)
        terminalMirrorHydrationNeededSurfaceIDs.remove(surfaceID)
        diagnosedTerminalOutputSurfaceIDs.remove(surfaceID)
        recordAppEvent(
            .terminalUnmounted,
            correlationID: surfaceID
        )
        // Tell the Mac this device is no longer viewing the surface so it can unpin and clear its border.
        clearTerminalViewport(surfaceID: surfaceID)
    }

    /// The output byte stream for a terminal surface.
    ///
    /// Obtaining the stream arms a cold-attach replay so the surface catches up
    /// to current state; ending iteration (or cancelling the consuming task)
    /// unregisters the surface and clears its viewport pin on the Mac.
    /// - Parameter surfaceID: The terminal surface identifier.
    /// - Returns: An `AsyncStream` of output byte chunks.
    public func terminalOutputStream(
        surfaceID: String
    ) -> AsyncStream<MobileTerminalOutputChunk> {
        terminalOutputStream(surfaceID: surfaceID, ownerID: nil)
    }

    /// The owner-aware output stream for a terminal surface.
    ///
    /// - Parameter surfaceID: The terminal surface identifier.
    /// - Parameter ownerID: Optional identity for the mounted UI consumer.
    /// - Returns: An `AsyncStream` of output byte chunks.
    public func terminalOutputStream(
        surfaceID: String,
        ownerID: UUID?
    ) -> AsyncStream<MobileTerminalOutputChunk> {
        AsyncStream { continuation in
            let streamToken = registerTerminalOutput(
                surfaceID: surfaceID,
                continuation: continuation,
                ownerID: ownerID
            )
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.unregisterTerminalOutput(
                        surfaceID: surfaceID,
                        streamToken: streamToken
                    )
                }
            }
        }
    }

    /// Returns whether a mounted UI consumer still owns the current output
    /// registration for a surface. A replacement stream intentionally leaves
    /// the old stream's termination asynchronous, so callers must use this
    /// identity instead of treating an un-cancelled iterator exit as failure.
    public func isTerminalOutputConsumerOwner(
        surfaceID: String,
        ownerID: UUID
    ) -> Bool {
        terminalOutputConsumerOwnerIDsBySurfaceID[surfaceID] == ownerID
    }

    /// Releases an owner identity at an explicit mount teardown boundary. The
    /// identity otherwise remains briefly after stream termination so the
    /// owning coordinator can distinguish a genuine failure from replacement.
    public func clearTerminalOutputConsumerOwner(
        surfaceID: String,
        ownerID: UUID
    ) {
        guard terminalOutputConsumerOwnerIDsBySurfaceID[surfaceID] == ownerID else {
            return
        }
        terminalOutputConsumerOwnerIDsBySurfaceID.removeValue(forKey: surfaceID)
    }

    func shouldDropRenderGridBehindPendingInput(_ renderGrid: MobileTerminalRenderGridFrame, source: String) -> Bool {
        if source == "replay",
           let pendingSeq = pendingTerminalByteEndSeqBySurfaceID[renderGrid.surfaceID],
           renderGrid.stateSeq >= pendingSeq { return false }
        guard let pendingSeq = pendingTerminalByteEndSeqBySurfaceID[renderGrid.surfaceID],
              renderGrid.stateSeq < pendingSeq else {
            guard pendingTerminalInputDroppedRenderGridSurfaceIDs.contains(renderGrid.surfaceID),
                  !renderGrid.full,
                  !renderGrid.isReplaceableViewportPatchForMobileDelivery else {
                return false
            }
            MobileDebugLog.anchormux("sync.render_grid_wait_replay source=\(source) surface=\(renderGrid.surfaceID) frame=\(renderGrid.stateSeq)")
            if source == "event" {
                requestTerminalReplayAfterDroppedRenderGrid(surfaceID: renderGrid.surfaceID, source: source)
            }
            return true
        }
        pendingTerminalInputDroppedRenderGridSurfaceIDs.insert(renderGrid.surfaceID)
        MobileDebugLog.anchormux("sync.render_grid_wait_input source=\(source) surface=\(renderGrid.surfaceID) frame=\(renderGrid.stateSeq) pending=\(pendingSeq)")
        if source == "event",
           terminalOutputTransport == .hybrid,
           terminalActiveScreenBySurfaceID[renderGrid.surfaceID] == .alternate,
           renderGrid.activeScreen == .primary {
            // The dropped frame may be the only signal that the host left the
            // alternate screen. Hybrid keeps suppressing raw primary bytes
            // while the tracked screen stays alternate, so without a replay
            // the surface can wedge on stale TUI content. Bounded by the
            // replay retry budget.
            requestTerminalReplayAfterDroppedRenderGrid(surfaceID: renderGrid.surfaceID, source: source)
        }
        return true
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

    /// Cold-attach/self-heal replay. Prefer the Mac's bounded render-grid
    /// snapshot, replacing the local iOS terminal state before live bytes
    /// resume. The VT snapshot and raw byte ring remain fallbacks, but neither
    /// is the target architecture: a byte tail is not a complete screen state
    /// for TUIs, and a VT export is still a replay stream rather than state.
    func requestTerminalReplay(
        surfaceID: String,
        replayBarrierToken: UUID? = nil,
        coveredReplayBarrierDroppedOutputCount: UInt64? = nil
    ) {
        if let replayBarrierToken, terminalReplayBarrierTokensBySurfaceID[surfaceID] != replayBarrierToken { return }; let replayBarrierTokenForRequest = replayBarrierToken
            ?? terminalReplayBarrierTokensBySurfaceID[surfaceID]
        if replayBarrierToken == nil, terminalViewportReplayBarrierPendingAckTokensBySurfaceID[surfaceID] != nil {
            // A pending viewport acknowledgement owns the next replay
            // decision. Record the suppressed request as owed output so the
            // report's resolution (resize or not) replays instead of clearing
            // the barrier with this recovery replay silently discarded.
            terminalReplayBarrierDroppedOutputSurfaceIDs.insert(surfaceID)
            return
        }
        let coveredReplayBarrierDroppedOutputCountForRequest = replayBarrierTokenForRequest == nil
            ? nil
            : (coveredReplayBarrierDroppedOutputCount
                ?? terminalReplayBarrierDroppedOutputCountsBySurfaceID[surfaceID]
                ?? 0)
        guard let client = remoteClient else {
            clearTerminalReplayBarrierIfCurrent(
                surfaceID: surfaceID,
                token: replayBarrierTokenForRequest,
                reason: "no_remote_client"
            )
            #if DEBUG
            mobileShellLog.error("CMUX_REPLAY skip surface=\(surfaceID, privacy: .public) reason=no_remote_client")
            #endif
            return
        }
        guard let workspaceID = workspaceID(forTerminalID: surfaceID) else {
            clearTerminalReplayBarrierIfCurrent(
                surfaceID: surfaceID,
                token: replayBarrierTokenForRequest,
                reason: "workspace_not_found"
            )
            #if DEBUG
            mobileShellLog.error("CMUX_REPLAY skip surface=\(surfaceID, privacy: .public) reason=workspace_not_found")
            #endif
            return
        }
        let remoteWorkspaceID = remoteWorkspaceID(for: workspaceID)
        if let replayBarrierTokenForRequest {
            guard terminalReplayBarrierTokensInFlightBySurfaceID[surfaceID] != replayBarrierTokenForRequest else {
                #if DEBUG
                mobileShellLog.info("CMUX_REPLAY skip surface=\(surfaceID, privacy: .public) reason=barrier_in_flight")
                #endif
                return
            }
        } else {
            guard !terminalReplaySurfaceIDsInFlight.contains(surfaceID) else {
                #if DEBUG
                mobileShellLog.info("CMUX_REPLAY skip surface=\(surfaceID, privacy: .public) reason=in_flight")
                #endif
                return
            }
        }
        let replayRequestID = UUID()
        let fullReplacementGenerationAtRequest =
            terminalFullReplacementGenerationBySurfaceID[surfaceID] ?? 0
        markTerminalReplayInFlight(
            surfaceID: surfaceID,
            requestID: replayRequestID,
            replayBarrierToken: replayBarrierTokenForRequest
        )
        let diagnosticStartedAt = appDiagnosticNow()
        recordAppEvent(
            .terminalReplayStarted,
            correlationID: surfaceID
        )
        // Snapshot the phone's reported viewport before spawning the request so
        // client_id and the dimensions travel together or not at all; the Mac
        // applies them ahead of capturing the frame, so the cold-attach replay
        // comes back already sized to this device's effective grid.
        let viewportKey = MobileTerminalViewportKey(
            workspaceID: workspaceID,
            terminalID: MobileTerminalPreview.ID(rawValue: surfaceID)
        )
        let reportedViewport = reportedViewportSizesByTerminalKey[viewportKey]
            .map { (clientID: clientID, columns: $0.columns, rows: $0.rows,
                    generation: terminalViewportGeneration(for: surfaceID)) }
        let replayTask = Task { @MainActor [weak self] in
            let replayResult: Result<Data, any Error>
            do {
                var params: [String: Any] = [
                    "workspace_id": remoteWorkspaceID.rawValue,
                    "surface_id": surfaceID,
                ]
                if let reportedViewport {
                    params["client_id"] = reportedViewport.clientID
                    params["viewport_columns"] = reportedViewport.columns
                    params["viewport_rows"] = reportedViewport.rows
                    if let generation = reportedViewport.generation {
                        params["viewport_generation"] = Int(clamping: generation)
                    }
                }
                // Screen-anchored replays hydrate this device's deep local
                // scrollback only when the mirror has none (cold attach, a
                // rebuilt-blank surface). Steady-state replays request no
                // scrollback and replay as history-preserving repaints, so
                // replay-barrier churn during streaming stays cheap and never
                // destroys locally accumulated history.
                if let self, self.usesScreenAnchoredRenderGrid {
                    params["anchor"] = MobileTerminalRenderGridFrame.Anchor.screen.rawValue
                    let needsHydration =
                        self.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == nil
                        || self.terminalMirrorHydrationNeededSurfaceIDs.contains(surfaceID)
                    params["max_scrollback_rows"] = needsHydration
                        ? MobileTerminalScrollbackPreference.resolve()
                        : 0
                }
                let request = try MobileCoreRPCClient.requestData(
                    method: "mobile.terminal.replay",
                    params: params
                )
                replayResult = .success(try await client.sendRequest(request))
            } catch {
                replayResult = .failure(error)
            }
            guard let self else { return }
            var transferredInFlightToRetry = false
            defer {
                if !transferredInFlightToRetry {
                    self.clearTerminalReplayInFlightIfCurrent(
                        surfaceID: surfaceID,
                        requestID: replayRequestID
                    )
                }
            }
            switch replayResult {
            case .success(let data):
                guard self.terminalReplayRequestIDsInFlightBySurfaceID[surfaceID] == replayRequestID else {
                    MobileDebugLog.anchormux("CMUX_REPLAY stale_request surface=\(surfaceID)")
                    return
                }
                guard self.remoteClient === client else {
                    self.clearTerminalReplayInFlightIfCurrent(
                        surfaceID: surfaceID,
                        requestID: replayRequestID
                    )
                    transferredInFlightToRetry = true
                    guard self.requestTerminalReplayForCurrentBarrier(
                        surfaceID: surfaceID,
                        replayBarrierToken: replayBarrierTokenForRequest,
                        coveredReplayBarrierDroppedOutputCount: nil,
                        reason: "stale_client"
                    ) else {
                        self.clearTerminalReplayBarrierIfCurrent(
                            surfaceID: surfaceID,
                            token: replayBarrierTokenForRequest,
                            reason: "stale_client"
                        )
                        return
                    }
                    return
                }
                let payload = try? MobileTerminalReplayResponse.decode(data)
                let bytes = payload?.dataBase64.flatMap { Data(base64Encoded: $0) }
                let snapshotBytes = payload?.snapshotBase64.flatMap { Data(base64Encoded: $0) }
                let decodedRenderGrid = payload?.renderGrid
                let renderGrid = decodedRenderGrid?.surfaceID == surfaceID ? decodedRenderGrid : nil
                let replaySeq = renderGrid?.stateSeq ?? payload?.sequence
                if let replayBarrierTokenForRequest {
                    guard self.terminalReplayBarrierTokensBySurfaceID[surfaceID] == replayBarrierTokenForRequest else {
                        MobileDebugLog.anchormux("CMUX_REPLAY barrier_stale surface=\(surfaceID)")
                        return
                    }
                }
                #if DEBUG
                let seq = replaySeq ?? 0
                let cols = payload?.columns ?? -1
                let rows = payload?.rows ?? -1
                mobileShellLog.info("CMUX_REPLAY response surface=\(surfaceID, privacy: .public) byteCount=\(bytes?.count ?? -1, privacy: .public) snapshotBytes=\(snapshotBytes?.count ?? -1, privacy: .public) renderGrid=\(renderGrid != nil, privacy: .public) seq=\(seq, privacy: .public) macGrid=\(cols, privacy: .public)x\(rows, privacy: .public) hasSink=\(self.hasTerminalOutputSink(surfaceID: surfaceID), privacy: .public)")
                #endif
                if let replaySeq {
                    let deliveredSeqValue = self.deliveredTerminalByteEndSeqBySurfaceID[surfaceID]
                    let deliveredSeq = deliveredSeqValue ?? 0
                    let observedFullReplacementSeq =
                        self.terminalFullReplacementSeqBySurfaceID[surfaceID] ?? 0
                    let fullReplacementMakesReplayStale =
                        deliveredSeqValue.map { $0 >= replaySeq } ?? false
                            && (
                                observedFullReplacementSeq > replaySeq
                                    || (
                                        observedFullReplacementSeq == replaySeq
                                            && (self.terminalFullReplacementGenerationBySurfaceID[surfaceID] ?? 0)
                                                > fullReplacementGenerationAtRequest
                                    )
                            )
                    if deliveredSeq > replaySeq
                        || fullReplacementMakesReplayStale {
                        MobileDebugLog.anchormux("CMUX_REPLAY stale surface=\(surfaceID) delivered=\(deliveredSeq) replay=\(replaySeq)")
                        self.consumeTerminalReplayFailureRetryAfterNoProgress(
                            surfaceID: surfaceID,
                            reason: "stale_sequence"
                        )
                        self.clearTerminalReplayBarrierIfCurrent(
                            surfaceID: surfaceID,
                            token: replayBarrierTokenForRequest,
                            reason: "stale_sequence"
                        )
                        return
                    }
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
                if let renderGrid {
                    guard !self.shouldDropRenderGridBehindPendingInput(renderGrid, source: "replay") else {
                        transferredInFlightToRetry = self.recoverAfterDroppedReplayFrame(
                            surfaceID: surfaceID,
                            replayBarrierToken: replayBarrierTokenForRequest,
                            replayRequestID: replayRequestID,
                            coveredReplayBarrierDroppedOutputCount: coveredReplayBarrierDroppedOutputCountForRequest,
                            reason: "pending_input_drop"
                        )
                        return
                    }
                    let accepted = self.deliverTerminalRenderGrid(
                        renderGrid,
                        surfaceID: surfaceID,
                        bypassReplayBarrier: replayBarrierTokenForRequest != nil
                    )
                    guard accepted else {
                        transferredInFlightToRetry = self.recoverAfterDroppedReplayFrame(
                            surfaceID: surfaceID,
                            replayBarrierToken: replayBarrierTokenForRequest,
                            replayRequestID: replayRequestID,
                            coveredReplayBarrierDroppedOutputCount: coveredReplayBarrierDroppedOutputCountForRequest,
                            reason: "not_delivered"
                        )
                        return
                    }
                    if self.terminalReplayBarrierAckStreamTokensBySurfaceID[surfaceID] != nil {
                        if let coveredReplayBarrierDroppedOutputCountForRequest {
                            self.terminalReplayBarrierAckCoveredDroppedOutputCountsBySurfaceID[surfaceID] =
                                coveredReplayBarrierDroppedOutputCountForRequest
                        } else {
                            self.terminalReplayBarrierAckCoveredDroppedOutputCountsBySurfaceID.removeValue(forKey: surfaceID)
                        }
                    }
                    self.recordTerminalRenderGridDelivery(renderGrid)
                    self.recordTerminalRenderGridHistoryContinuity(renderGrid)
                    self.rebaseTerminalReplayStaleFloor(surfaceID: surfaceID)
                    // A delivered grid is progress even if the payload omitted
                    // its sequence; fall back to the frame's own sequence so
                    // the pending-input drop marker cannot outlive the replay.
                    self.markTerminalBytesDelivered(
                        surfaceID: surfaceID,
                        endSeq: replaySeq ?? renderGrid.stateSeq,
                        fullReplacement: renderGrid.full
                    )
                    self.recordAppEvent(
                        .terminalReplaySucceeded,
                        correlationID: surfaceID,
                        startedAt: diagnosticStartedAt,
                        count: renderGrid.rowSpans.count
                    )
                    return
                }
                guard let deliverBytes, !deliverBytes.isEmpty else {
                    if self.terminalReplayBarrierDroppedOutputSurfaceIDs.contains(surfaceID),
                       let retryToken = self.prepareTerminalReplayFailureRetry(
                        surfaceID: surfaceID,
                        replayBarrierToken: replayBarrierTokenForRequest
                       ) {
                        self.clearTerminalReplayInFlightIfCurrent(
                            surfaceID: surfaceID,
                            requestID: replayRequestID
                        )
                        transferredInFlightToRetry = true
                        self.requestTerminalReplay(
                            surfaceID: surfaceID,
                            replayBarrierToken: retryToken,
                            coveredReplayBarrierDroppedOutputCount:
                                self.terminalReplayBarrierDroppedOutputCountsBySurfaceID[surfaceID]
                        )
                        return
                    }
                    self.consumeTerminalReplayFailureRetryAfterNoProgress(
                        surfaceID: surfaceID,
                        reason: "empty"
                    )
                    self.clearTerminalReplayBarrierIfCurrent(
                        surfaceID: surfaceID,
                        token: replayBarrierTokenForRequest,
                        reason: "empty"
                    )
                    return
                }
                let accepted = self.deliverTerminalBytes(
                    deliverBytes,
                    surfaceID: surfaceID,
                    endSequence: replaySeq,
                    bypassReplayBarrier: replayBarrierTokenForRequest != nil
                )
                if accepted,
                   self.terminalReplayBarrierAckStreamTokensBySurfaceID[surfaceID] != nil {
                    if let coveredReplayBarrierDroppedOutputCountForRequest {
                        self.terminalReplayBarrierAckCoveredDroppedOutputCountsBySurfaceID[surfaceID] =
                            coveredReplayBarrierDroppedOutputCountForRequest
                    } else {
                        self.terminalReplayBarrierAckCoveredDroppedOutputCountsBySurfaceID.removeValue(forKey: surfaceID)
                    }
                }
                if accepted, let replaySeq {
                    // Only a sequence-carrying acceptance re-bases the stale
                    // floor; a seq-less tail leaves it for the ack restore.
                    self.rebaseTerminalReplayStaleFloor(surfaceID: surfaceID)
                    self.markTerminalBytesDelivered(
                        surfaceID: surfaceID,
                        endSeq: replaySeq,
                        fullReplacement: snapshotBytes?.isEmpty == false
                    )
                } else if accepted {
                    self.consumeTerminalReplayFailureRetryAfterNoProgress(
                        surfaceID: surfaceID,
                        reason: "bytes_no_seq"
                    )
                } else {
                    self.clearTerminalReplayBarrierIfCurrent(
                        surfaceID: surfaceID,
                        token: replayBarrierTokenForRequest,
                        reason: "not_delivered",
                        preserveDroppedOutput: true
                    )
                }
                self.recordAppEvent(
                    accepted ? .terminalReplaySucceeded : .terminalReplayFailed,
                    correlationID: surfaceID,
                    startedAt: diagnosticStartedAt,
                    failure: accepted ? nil : .protocolViolation,
                    count: accepted ? deliverBytes.count : nil
                )
            case .failure(let error):
                guard self.terminalReplayRequestIDsInFlightBySurfaceID[surfaceID] == replayRequestID else {
                    MobileDebugLog.anchormux("CMUX_REPLAY stale_request_failed surface=\(surfaceID)")
                    return
                }
                mobileShellLog.error("CMUX_REPLAY failed surface=\(surfaceID, privacy: .public) error=\(String(describing: error), privacy: .private)")
                self.recordAppEvent(
                    .terminalReplayFailed,
                    correlationID: surfaceID,
                    startedAt: diagnosticStartedAt,
                    failure: DiagnosticFailureKind.classify(error)
                )
                guard self.remoteClient === client else {
                    self.clearTerminalReplayInFlightIfCurrent(
                        surfaceID: surfaceID,
                        requestID: replayRequestID
                    )
                    transferredInFlightToRetry = true
                    guard self.requestTerminalReplayForCurrentBarrier(
                        surfaceID: surfaceID,
                        replayBarrierToken: replayBarrierTokenForRequest,
                        coveredReplayBarrierDroppedOutputCount: nil,
                        reason: "stale_client"
                    ) else {
                        self.clearTerminalReplayBarrierIfCurrent(
                            surfaceID: surfaceID,
                            token: replayBarrierTokenForRequest,
                            reason: "stale_client"
                        )
                        return
                    }
                    return
                }
                // The replay request is the view-only/foreground-resume path. A
                // definitive auth failure here (after the RPC layer's
                // force-refresh-and-retry already gave up) must drive the re-auth
                // prompt instead of silently leaving a stale frame.
                guard !self.disconnectForAuthorizationFailureIfNeeded(error) else { return }
                if self.isTerminalReplayViewportTransition(error) {
                    // Ghostty is still applying the viewport reported by this
                    // request. Do not consume replay retries or fail the
                    // barrier open while the host is publishing the settled
                    // full grid. The next live grid is the synchronization
                    // signal; a dropped grid will request the replay through
                    // the normal barrier path once this task has settled.
                    _ = self.armTerminalReplayBarrierForViewportTransition(
                        surfaceID: surfaceID,
                        token: replayBarrierTokenForRequest,
                    )
                    MobileDebugLog.anchormux(
                        "CMUX_REPLAY defer_viewport_transition surface=\(surfaceID)"
                    )
                    return
                }
                if let retryToken = self.prepareTerminalReplayFailureRetry(
                    surfaceID: surfaceID,
                    replayBarrierToken: replayBarrierTokenForRequest
                ) {
                    self.recordAppEvent(
                        .terminalReplayRetried,
                        correlationID: surfaceID
                    )
                    self.clearTerminalReplayInFlightIfCurrent(
                        surfaceID: surfaceID,
                        requestID: replayRequestID
                    )
                    transferredInFlightToRetry = true
                    self.requestTerminalReplay(
                        surfaceID: surfaceID,
                        replayBarrierToken: retryToken,
                        coveredReplayBarrierDroppedOutputCount: coveredReplayBarrierDroppedOutputCountForRequest
                    )
                    return
                }
                if replayBarrierTokenForRequest == nil {
                    self.consumeTerminalReplayFailureRetryAfterNoProgress(
                        surfaceID: surfaceID,
                        reason: "request_failed"
                    )
                }
                self.resolveTerminalReplayFailureBarrier(surfaceID: surfaceID, token: replayBarrierTokenForRequest)
            }
        }
        storeTerminalReplayTask(
            surfaceID: surfaceID,
            requestID: replayRequestID,
            task: replayTask
        )
    }

    private func handleTerminalRenderGridEvent(_ event: MobileEventEnvelope) {
        guard let json = event.payloadJSON else {
            return
        }
        #if DEBUG
        let latencyReceiveTime = MobileLatencyTrace.captureTime()
        #endif
        // The frame may arrive nested under `render_grid` or as the bare payload;
        // try the wrapper first, then fall back to decoding the whole payload.
        let renderGridDTO = try? MobileTerminalRenderGridEvent.decode(json)
        guard let renderGrid = renderGridDTO?.frame ?? (try? MobileTerminalRenderGridFrame.decode(json)),
              hasTerminalOutputSink(surfaceID: renderGrid.surfaceID) else {
            return
        }
        if diagnosedTerminalOutputSurfaceIDs.insert(renderGrid.surfaceID).inserted {
            recordAppEvent(
                .terminalOutputReceived,
                correlationID: renderGrid.surfaceID,
                count: json.count
            )
        }
        #if DEBUG
        if let latencyReceiveTime {
            let decodeDuration = MobileLatencyTrace.elapsedMicroseconds(since: latencyReceiveTime)
            MobileLatencyTrace.stamp(
                "ev.grid",
                at: latencyReceiveTime,
                "s=\(renderGrid.surfaceID.prefix(8).lowercased()) seq=\(renderGrid.stateSeq) " +
                    "bytes=\(json.count) dec_us=\(decodeDuration)"
            )
        }
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
            await clearDeliveredNotifications(
                ids: payload.ids,
                macDeviceID: foregroundMacDeviceID,
                instanceTag: activeMacInstanceTag
            )
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
        guard !terminalLaneOutputReadySurfaceIDs.contains(surfaceID) else { return }
        if diagnosedTerminalOutputSurfaceIDs.insert(surfaceID).inserted {
            recordAppEvent(
                .terminalOutputReceived,
                correlationID: surfaceID,
                count: bytes.count
            )
        }
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
                recordAppEvent(
                    .terminalOutputGapDetected,
                    correlationID: surfaceID,
                    count: Int(clamping: seq - deliveredSeq)
                )
                mobileShellLog.info("terminal byte gap surface=\(surfaceID, privacy: .public) deliveredSeq=\(deliveredSeq, privacy: .public) nextSeq=\(seq, privacy: .public)")
                guard deliverTerminalBytes(bytes, surfaceID: surfaceID, endSequence: endSeq) else { return }
                markTerminalBytesDelivered(surfaceID: surfaceID, endSeq: endSeq)
                if terminalReplaySurfaceIDsInFlight.contains(surfaceID) {
                    cancelTerminalReplayInFlight(surfaceID: surfaceID)
                }
                // The gap bytes were already accepted as the newest live
                // state. Keep the catch-up replay nonblocking so later live
                // bytes continue while it verifies the missing interval.
                refreshTerminalOutputSubscription(reason: "seq_gap", restartEventStream: false)
                requestTerminalReplay(surfaceID: surfaceID)
                return
            }
            if endSeq <= deliveredSeq {
                return
            }
            let overlap = deliveredSeq - seq
            let deliverBytes = Data(bytes.dropFirst(Int(overlap)))
            guard deliverTerminalBytes(deliverBytes, surfaceID: surfaceID, endSequence: endSeq) else { return }
            markTerminalBytesDelivered(surfaceID: surfaceID, endSeq: endSeq)
            return
        }
        // With no live baseline, the pre-barrier floor is the effective
        // delivered mark: pre-barrier chunks must not repaint or count.
        if let floorSeq = terminalPreBarrierDeliveredEndSeqBySurfaceID[surfaceID] {
            if endSeq <= floorSeq {
                MobileDebugLog.anchormux("sync.bytes_below_floor surface=\(surfaceID) floor=\(floorSeq) end=\(endSeq)")
                return
            }
            if seq < floorSeq {
                let overlap = floorSeq - seq
                let deliverBytes = Data(bytes.dropFirst(Int(overlap)))
                guard deliverTerminalBytes(deliverBytes, surfaceID: surfaceID, endSequence: endSeq) else { return }
                markTerminalBytesDelivered(surfaceID: surfaceID, endSeq: endSeq)
                return
            }
        }
        guard deliverTerminalBytes(bytes, surfaceID: surfaceID, endSequence: endSeq) else { return }
        markTerminalBytesDelivered(surfaceID: surfaceID, endSeq: endSeq)
    }

    /// Dedicated missed-event-window repair (the watchdog's lost-registration
    /// branch): events emitted while the host had dropped this connection's
    /// registration were lost, deltas included. Under v2, repair is a cursor
    /// fetch; under legacy it is the full-list refetch. Ordinary paired
    /// `workspace.updated` events never route here.
    func repairMissedEventWindow() {
        if stateSyncActive {
            if let client = remoteClient {
                requestStateSyncFetch(client: client)
            }
            return
        }
        scheduleWorkspaceListRefreshFromEvent()
    }

    private func scheduleWorkspaceListRefreshFromEvent() {
        guard remoteClient != nil else { return }
        // With state sync v2 negotiated, `workspace.updated` is redundant with
        // the `mobile.sync.delta` stream (the Mac emits both on the same tick
        // for old and new phones); the delta already carried the change, so
        // fetching here would add a per-event RPC and Mac-side rebuild, and
        // its cancel-and-replace slot could starve a genuine gap repair.
        // "Events were missed" recovery has its own dedicated entry
        // (``repairMissedEventWindow``); ordinary paired events stay silent.
        guard !stateSyncActive else { return }
        // This generation represents a scheduled legacy full-list refresh.
        // State-sync events above have their own revision authority and must
        // not look like unawaited legacy work to pooled-client promotion.
        workspaceListEventGeneration &+= 1
        // Keep the event path's "latest event wins" semantics: a `workspace.updated`
        // arriving mid-fetch restarts the fetch so the applied list reflects the
        // change the Mac pushed *after* this fetch started. This cancels only the
        // event-driven task handle; the user pull-to-refresh runs on its own
        // (``pullToRefreshTask``) so an event can never truncate its spinner.
        workspaceListRefreshTask?.cancel()
        let operationID = UUID()
        workspaceListRefreshOperationID = operationID
        workspaceListRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return false }
            defer {
                if self.workspaceListRefreshOperationID == operationID {
                    self.workspaceListRefreshTask = nil
                    self.workspaceListRefreshOperationID = nil
                }
            }
            let refreshed = await self.reloadWorkspaceListFromMac()
            if refreshed {
                self.scheduleWorkspaceChangesSummaryRefresh()
            }
            return refreshed
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
            if self?.connectionState == .connected,
               self?.remoteClient != nil {
                await self?.refreshSecondaryMacWorkspaces(
                    discoverLivePeers: true
                )
            }
        }
        pullToRefreshTask = task
        await task.value
    }

    func stopTerminalRefreshPolling() {
        cancelTerminalInputAckResubscribeRetry()
        terminalEventListenerTask?.cancel()
        terminalEventListenerTask = nil
        terminalEventListenerID = nil
        terminalSubscriptionStartTask?.cancel()
        terminalSubscriptionStartTask = nil
        stopRenderGridLivenessWatchdog(listenerID: nil)
    }

    /// Stop admitting terminal subscription work, then await every request that
    /// may already have reached the Mac. The final unsubscribe is safe only
    /// after this drain, because the host executes request handlers
    /// concurrently and a late subscribe could otherwise recreate render
    /// ownership after demotion.
    func prepareTerminalSubscriptionHandoff(
        on client: MobileCoreRPCClient
    ) async -> Bool {
        guard let pending = beginTerminalSubscriptionHandoff(on: client) else {
            return false
        }
        let drain = await Self.raceAgainstDeadline(
            nanoseconds: connectionHandoffDrainTimeoutNanoseconds
        ) {
            await pending.startTask?.value
            await pending.refreshTask?.value
            await pending.probeTask?.value
            return true
        }
        let prepared = drain.value == true
            && !drain.wasCancelled
            && remoteClient === client
            && terminalSubscriptionHandoffFences[ObjectIdentifier(client)]?
                .fenceID == pending.fenceID
        if !prepared {
            // The caller abandons this handoff (and usually disconnects the
            // client), so the fence must not outlive it: a leaked entry can
            // block a later client that reuses the same object identity.
            finishTerminalSubscriptionHandoff(pending)
        }
        return prepared
    }

    /// Fence a focused client's terminal registration and move every in-flight
    /// request into an explicit handoff value without awaiting the wire.
    func beginTerminalSubscriptionHandoff(
        on client: MobileCoreRPCClient
    ) -> PendingTerminalSubscriptionHandoff? {
        guard remoteClient === client else { return nil }
        let clientID = ObjectIdentifier(client)

        terminalEventListenerTask?.cancel()
        terminalEventListenerTask = nil
        terminalEventListenerID = nil
        renderGridLivenessTimer?.cancel()
        renderGridLivenessTimer = nil
        renderGridLivenessListenerID = nil
        renderGridLivenessConsecutiveProbeFailures = 0

        let start = terminalSubscriptionStartTask
        let refresh = terminalSubscriptionRefreshTask
        let probe = renderGridLivenessProbeTask
        terminalSubscriptionStartTask = nil
        terminalSubscriptionRefreshTask = nil
        renderGridLivenessProbeTask = nil
        renderGridLivenessProbeID = nil
        let pending = PendingTerminalSubscriptionHandoff(
            client: client,
            fenceID: UUID(),
            startTask: start,
            refreshTask: refresh,
            probeTask: probe
        )
        terminalSubscriptionHandoffFences[clientID] = pending
        return pending
    }

    /// Await a retired peer's captured requests without blocking the focus
    /// transition. Each RPC owns its existing timeout.
    func drainTerminalSubscriptionHandoff(
        _ pending: PendingTerminalSubscriptionHandoff
    ) async {
        await pending.startTask?.value
        await pending.refreshTask?.value
        await pending.probeTask?.value
    }

    func finishTerminalSubscriptionHandoff(
        _ pending: PendingTerminalSubscriptionHandoff
    ) {
        let clientID = ObjectIdentifier(pending.client)
        guard terminalSubscriptionHandoffFences[clientID]?.fenceID
                == pending.fenceID else {
            return
        }
        terminalSubscriptionHandoffFences[clientID] = nil
    }

    /// Run one owned focus-transition maintenance operation for `client`,
    /// cancelling any older instance still maintaining the same client.
    func startFocusTransitionMaintenance(
        for client: MobileCoreRPCClient,
        _ operation: @escaping @MainActor () async -> Void
    ) {
        let clientID = ObjectIdentifier(client)
        focusTransitionMaintenanceTasks[clientID]?.task.cancel()
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            await operation()
            guard let self,
                  self.focusTransitionMaintenanceTasks[clientID]?.token
                    == token else {
                return
            }
            self.focusTransitionMaintenanceTasks[clientID] = nil
        }
        focusTransitionMaintenanceTasks[clientID] = (token, task)
    }

    func cancelAllFocusTransitionMaintenance() {
        for entry in focusTransitionMaintenanceTasks.values {
            entry.task.cancel()
        }
        focusTransitionMaintenanceTasks.removeAll()
    }

    func setSelectedWorkspaceID(_ id: MobileWorkspacePreview.ID?) {
        guard selectedWorkspaceID != id else { return }
        selectedWorkspaceID = id
    }

    func applyRemoteWorkspaceList(
        _ response: MobileSyncWorkspaceListResponse,
        preferActiveTicketTarget: Bool = false,
        forceForegroundSelection: Bool = false,
        mergeExistingWorkspaces: Bool = false,
        groupsAreAuthoritative: Bool = true,
        changesSummaryRefreshScope: WorkspaceChangesSummaryRefreshScope = .fullSnapshot
    ) {
        foregroundWorkspaceStateRevision &+= 1
        let remoteWorkspaces = remoteWorkspacesPreservingSnapshots(from: response)
        // Write the foreground Mac's per-Mac state; `workspaces` / `workspaceGroups`
        // recompute from the source of truth automatically (no explicit merge or
        // publish). Group sections are authoritative only on a full-list response:
        // a merge path or scoped attach response omits groups, so pass nil there
        // to leave the existing sections intact. Authoritative groups are passed
        // through the device-local collapse store before entering the per-Mac
        // source of truth, so derived groups keep this phone's collapse choices.
        // Empty or missing group metadata during reconnect/rebind is not enough to
        // remove sections; only a healthy, complete ungrouped snapshot can do that.
        let groups = remoteWorkspaceGroups(
            from: response,
            mergeExistingWorkspaces: mergeExistingWorkspaces,
            groupsAreAuthoritative: groupsAreAuthoritative
        )
        setForegroundWorkspaceState(
            workspaces: remoteWorkspaces, groups: groups, merge: mergeExistingWorkspaces)
        #if DEBUG
        startLatencyProbeAutoNavigationIfNeeded()
        #endif
        reconcileWorkspaceChangesSummaryStateWithForeground()
        let changesSummaryWorkspaceIDs = changesSummaryRefreshScope.workspaceIDs(
            fullSnapshotWorkspaceIDs: response.workspaces.map(\.id)
        )
        if !changesSummaryWorkspaceIDs.isEmpty {
            // Repo-dirtiness filesystem invalidation is a known follow-up. Deltas,
            // TTL, trailing expiry, and force are this PR's bounded approximation.
            scheduleWorkspaceChangesSummaryRefresh(
                workspaceIDs: changesSummaryWorkspaceIDs
            )
        }
        if forceForegroundSelection {
            selectWorkspaceOnCurrentForegroundMac()
            return
        }
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
                rowWorkspaceID(
                    forRemoteWorkspaceID: $0,
                    macDeviceID: foregroundMacDeviceID,
                    instanceTag: activeMacInstanceTag
                )
            }
            ?? workspaces.first?.id
        )
        syncSelectedTerminalForWorkspace()
    }

    private func remoteWorkspaceGroups(
        from response: MobileSyncWorkspaceListResponse,
        mergeExistingWorkspaces: Bool,
        groupsAreAuthoritative: Bool
    ) -> [MobileWorkspaceGroupPreview]? {
        guard !mergeExistingWorkspaces, groupsAreAuthoritative else { return nil }
        return Self.remoteWorkspaceGroups(
            from: response,
            acceptsEmptyGroupSnapshot: canAcceptEmptyGroupSnapshot(from: response)
        )
    }

    /// Resolve one response's group-field completeness into update-or-preserve
    /// semantics shared by foreground and secondary workspace snapshots.
    private static func remoteWorkspaceGroups(
        from response: MobileSyncWorkspaceListResponse,
        acceptsEmptyGroupSnapshot: Bool
    ) -> [MobileWorkspaceGroupPreview]? {
        guard response.groupsFieldWasPresent else { return nil }
        let groups = response.groups.map { MobileWorkspaceGroupPreview(remote: $0) }
        guard groups.isEmpty else { return groups }
        return acceptsEmptyGroupSnapshot ? [] : nil
    }

    private func canAcceptEmptyGroupSnapshot(
        from response: MobileSyncWorkspaceListResponse
    ) -> Bool {
        guard connectionState == .connected, macConnectionStatus == .connected else {
            return false
        }
        let responseStillReferencesGroups = response.workspaces.contains { workspace in
            workspace.groupID?.isEmpty == false
        }
        guard !responseStillReferencesGroups else { return false }
        return true
    }

    private func remoteWorkspacesPreservingSnapshots(
        from response: MobileSyncWorkspaceListResponse
    ) -> [MobileWorkspacePreview] {
        let rawForegroundMacID = foregroundMacDeviceID
            ?? activeTicket?.macDeviceID
        let foregroundMacID = rawForegroundMacID?.isEmpty == false
            ? rawForegroundMacID
            : nil
        let existingWorkspacesByRemoteID = Dictionary(
            workspaces.lazy
                .filter { workspace in
                    guard let foregroundMacID, !foregroundMacID.isEmpty else { return true }
                    guard let workspaceMacDeviceID = workspace.macDeviceID else {
                        return false
                    }
                    return MacPairingKey(
                        macDeviceID: workspaceMacDeviceID,
                        instanceTag: workspace.macInstanceTag
                    ) == MacPairingKey(
                        macDeviceID: foregroundMacID,
                        instanceTag: self.activeMacInstanceTag
                    )
                }
                .map { ($0.rpcWorkspaceID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return response.workspaces.map { remoteWorkspace in
            var workspace = MobileWorkspacePreview(remote: remoteWorkspace)
            // Tag every workspace with the Mac it came from, so the aggregated
            // multi-Mac list can group and filter by machine (P1 of the multi-Mac
            // work). Today there is one connected Mac, so all rows share its id.
            workspace.macDeviceID = foregroundMacID
            workspace.macInstanceTag = activeMacInstanceTag
            guard let existingWorkspace = existingWorkspacesByRemoteID[workspace.id] else {
                return workspace
            }
            let existingTerminalsByID = Dictionary(
                existingWorkspace.terminals.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            workspace.terminals = workspace.terminals.map { remoteTerminal in
                guard
                    let existingTerminal = existingTerminalsByID[remoteTerminal.id]
                else {
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
        guard let workspaceID = rowWorkspaceID(
            forRemoteWorkspaceID: ticketWorkspaceID,
            macDeviceID: foregroundMacDeviceID ?? activeTicket.macDeviceID,
            instanceTag: activeMacInstanceTag
        ), let workspace = workspaces.first(where: { $0.id == workspaceID }) else {
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

    /// A Mac focus change must also move selection to a workspace owned by that
    /// Mac. Aggregate rows from the demoted Mac stay visible, so ordinary
    /// selection preservation cannot enforce this ownership boundary.
    func selectWorkspaceOnCurrentForegroundMac() {
        if selectActiveTicketTargetIfAvailable() {
            return
        }
        let target = workspaces.first { workspace in
            if let foregroundMacDeviceID {
                guard let workspaceMacDeviceID = workspace.macDeviceID else {
                    return false
                }
                return MacPairingKey(
                    macDeviceID: workspaceMacDeviceID,
                    instanceTag: workspace.macInstanceTag
                ) == MacPairingKey(
                    macDeviceID: foregroundMacDeviceID,
                    instanceTag: activeMacInstanceTag
                )
            }
            return workspace.macDeviceID == nil && workspace.macInstanceTag == nil
        }
        setSelectedWorkspaceID(target?.id)
        syncSelectedTerminalForWorkspace()
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
        recordPairingFailed(
            reason: category.analyticsReason,
            phase: "auth",
            failure: category.diagnosticFailureKind
        )
        return true
    }

    private static func shouldDisconnectForAuthorizationFailure(_ error: any Error) -> Bool {
        guard let connectionError = error as? MobileShellConnectionError else {
            return false
        }
        switch connectionError {
        case .attachTicketExpired, .authorizationFailed, .accountMismatch:
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
        case .invalidResponse, .connectionClosed, .requestTimedOut,
             .transportWriteTimedOut, .routeCleanupBlocked, .connectAttemptGated,
             .insecureManualRoute:
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
extension MobileShellComposite {
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
