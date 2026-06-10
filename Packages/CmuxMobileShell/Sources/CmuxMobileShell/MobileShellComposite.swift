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

let mobileShellLog = Logger(
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
    enum TerminalOutputTransport: Equatable {
        case renderGrid
        case rawBytes

        var eventTopics: [String] {
            switch self {
            case .renderGrid:
                return ["workspace.updated", "terminal.render_grid"]
            case .rawBytes:
                return ["workspace.updated", "terminal.bytes"]
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
    static let storedMacReconnectRestoringDeadlineSeconds: Double = 6

    static let terminalRenderGridCapability = "terminal.render_grid.v1"
    static let workspaceActionsCapability = "workspace.actions.v1"
    static let terminalOutputCapabilityTimeoutNanoseconds: UInt64 = 750_000_000

    /// How long the render-grid stream may stay silent (no event of any topic)
    /// before the liveness watchdog assumes the push subscription is dead and
    /// forces a re-subscribe + replay. Picked at the low end of the acceptable
    /// 8-12s window so a wedged stream recovers in a few seconds instead of the
    /// transport's ~85s timeout, while staying well above any normal inter-event
    /// gap on a busy shell.
    static let renderGridLivenessSilenceThreshold: TimeInterval = 9
    /// Cadence of the liveness watchdog tick. It only reads a timestamp and
    /// compares against the threshold, so a short interval is cheap; it does not
    /// reschedule per received event (an actively-streaming connection just keeps
    /// failing the silence check because `lastTerminalEventAt` stays fresh).
    static let renderGridLivenessCheckInterval: TimeInterval = 2.5

    public internal(set) var isSignedIn: Bool
    public internal(set) var connectionState: MobileConnectionState {
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
    public internal(set) var macConnectionStatus: MobileMacConnectionStatus
    public internal(set) var connectedHostName: String
    public internal(set) var connectionError: String?
    public internal(set) var activeTicket: CmxAttachTicket?
    public internal(set) var activeRoute: CmxAttachRoute?

    /// True only while an actually-found stored Mac is mid-reconnect.
    ///
    /// Set just before awaiting the connect for a Mac resolved from the paired-Mac
    /// store on launch (or network recovery), and cleared once that attempt
    /// resolves. Drives the root scene's choice to show ``RestoringSessionView``
    /// during the reconnect window instead of the empty add-device sheet.
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
    /// sign-out, forget) each claim a generation; only the current generation may
    /// resolve the restoring-gate flags, so a superseded older attempt can't clear
    /// the gate while a newer reconnect is still in progress.
    var storedMacReconnectGeneration = 0
    public var hasActiveUnexpiredAttachTicket: Bool {
        guard let activeTicket,
              activeTicket.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        return Self.attachTicketIsUnexpired(activeTicket, now: runtime?.now() ?? Date())
    }
    public var pairingCode: String
    public var workspaces: [MobileWorkspacePreview]
    /// Whether the connected Mac advertises the `workspace.actions.v1` capability
    /// (rename/pin over the mobile RPC). `false` until host status is read, and
    /// for older Macs that lack the handler, so the UI can hide rename/pin rather
    /// than offer actions that would fail with `method_not_found`.
    public internal(set) var supportsWorkspaceActions: Bool = false
    public var terminalInputText: String
    public var selectedWorkspaceID: MobileWorkspacePreview.ID? {
        didSet {
            syncSelectedTerminalForWorkspace()
        }
    }
    public var selectedTerminalID: MobileTerminalPreview.ID?

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
    var terminalAutoFocusSuppressedSurfaceIDs: Set<String> = []

    let runtime: (any MobileSyncRuntime)?
    let pairedMacStore: (any MobilePairedMacStoring)?
    /// Best-effort, team-scoped lookup of fresher attach routes from the device
    /// registry. Optional and failure-tolerant: when `nil` or unreachable,
    /// reconnect uses the locally persisted paired-Mac routes, so pairing
    /// survives the cloud registry being down.
    let deviceRegistry: (any DeviceRegistryRefreshing)?
    let identityProvider: (any MobileIdentityProviding)?
    let reachability: any ReachabilityProviding
    private let pairingHintDefaults: UserDefaults
    let clientID: String
    /// The injected, fire-and-forget product-analytics emitter. Defaults to
    /// ``NoopAnalytics`` so previews/tests inject nothing.
    let analytics: any AnalyticsEmitting
    /// Collapses connection-state edges into one-per-outage lost/recovered events.
    private var connectionOutageThrottle = ConnectionOutageThrottle()
    /// When the current outage began, for the recovered event's duration.
    private var connectionOutageStartedAt: Date?
    /// Set just before an intentional teardown drops `connectionState`, so the
    /// `didSet` swallows that edge instead of emitting a false `ios_connection_lost`.
    var suppressNextConnectionOutageEdge = false
    /// When the in-flight pairing attempt began, for `*_succeeded`/`_failed`
    /// `duration_ms`. Keyed implicitly by ``pairingAttemptID``.
    var pairingAttemptStartedAt: Date?
    /// The method (`qr`/`manual`/`attach_url`) of the in-flight pairing attempt.
    var pairingAttemptMethod: String?
    /// Whether this install had no known paired Mac at the *start* of the in-flight
    /// attempt. Snapshotted in ``beginPairingAttempt(method:)`` and reused for the
    /// started/succeeded/failed events, because a successful `connect(ticket:)`
    /// sets ``hasKnownPairedMac`` to `true` before `succeeded` is recorded — so
    /// reading it again would report the first successful pair as `is_first_pair:
    /// false` and break the first-pair funnel.
    var pairingAttemptIsFirstPair = false

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
    var terminalEventListenerTask: Task<Void, Never>?
    var terminalEventListenerID: UUID?
    // Liveness watchdog for the render-grid push subscription. The `for await`
    // listener loop blocks indefinitely if the underlying connection half-dies
    // (network blip, Mac stops pushing, background/foreground cycle): the
    // AsyncStream neither yields a new event nor finishes, so the loop sits
    // silent and the phone shows a stale frame while the Mac advances thousands
    // of render-grid deltas. The transport's own timeout (~85s) is far too slow.
    // A `DispatchSourceTimer` ticks independently of the (potentially wedged)
    // stream and compares "now" against the last received event to detect
    // prolonged silence, then tears down + re-subscribes + replays.
    var renderGridLivenessTimer: (any DispatchSourceTimer)?
    var renderGridLivenessListenerID: UUID?
    var lastTerminalEventAt: Date?
    var terminalSubscriptionRefreshTask: Task<Void, Never>?
    var createWorkspaceTask: Task<Void, Never>?
    var createTerminalTask: Task<Void, Never>?
    var workspaceListRefreshTask: Task<Void, Never>?
    var createWorkspaceTaskID: UUID?
    var createTerminalTaskID: UUID?
    var connectionGeneration: UUID
    var reportedViewportSizesByTerminalKey: [MobileTerminalViewportKey: MobileTerminalViewportSize]
    var deliveredTerminalByteEndSeqBySurfaceID: [String: UInt64]
    var pendingTerminalByteEndSeqBySurfaceID: [String: UInt64]
    var terminalReplaySurfaceIDsInFlight: Set<String>
    var terminalOutputTransport: TerminalOutputTransport
    var rawTerminalInputBuffer: MobileTerminalInputSendBuffer
    var pairingAttemptID: UUID

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

    var selectedTerminal: MobileTerminalPreview? {
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
    static func diagnosticSurfaceHandle(_ surfaceID: String) -> UInt32 {
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
        clientIDRepository: MobileClientIDRepository = MobileClientIDRepository(defaults: .standard),
        identityProvider: (any MobileIdentityProviding)? = nil,
        reachability: any ReachabilityProviding = ReachabilityService(),
        pairingHintDefaults: UserDefaults = .standard,
        analytics: any AnalyticsEmitting = NoopAnalytics(),
        diagnosticLog: DiagnosticLog? = nil
    ) {
        self.runtime = runtime
        self.pairedMacStore = pairedMacStore
        self.deviceRegistry = deviceRegistry
        self.identityProvider = identityProvider
        self.reachability = reachability
        self.pairingHintDefaults = pairingHintDefaults
        self.analytics = analytics
        self.diagnosticLog = diagnosticLog
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
        self.createWorkspaceTaskID = nil
        self.createTerminalTaskID = nil
        self.connectionGeneration = UUID()
        self.reportedViewportSizesByTerminalKey = [:]
        self.deliveredTerminalByteEndSeqBySurfaceID = [:]
        self.pendingTerminalByteEndSeqBySurfaceID = [:]
        self.terminalReplaySurfaceIDsInFlight = []
        self.terminalOutputTransport = .rawBytes
        self.rawTerminalInputBuffer = MobileTerminalInputSendBuffer()
        self.pairingAttemptID = UUID()
    }

    isolated deinit {
        networkPathObservationTask?.cancel()
        terminalEventListenerTask?.cancel()
        renderGridLivenessTimer?.cancel()
        terminalSubscriptionRefreshTask?.cancel()
        createWorkspaceTask?.cancel()
        createTerminalTask?.cancel()
        workspaceListRefreshTask?.cancel()
        if let remoteClient {
            Task { await remoteClient.disconnect() }
        }
    }

    public static func preview(runtime: (any MobileSyncRuntime)? = nil) -> CMUXMobileShellStore {
        CMUXMobileShellStore(runtime: runtime, workspaces: PreviewMobileHost.workspaces)
    }

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
    public internal(set) var connectionRequiresReauth: Bool = false

    var networkPathObservationStarted = false
    var networkPathObservationTask: Task<Void, Never>?
    var recoveryInFlight = false
    var recoveryTask: Task<Void, Never>?
    var lastReconnectStackUserID: String?

    /// Every Mac paired with this device, for the host switcher. Refreshed via
    /// ``loadPairedMacs()`` and after switch/forget. Cleared on sign-out so a
    /// shared device never shows the previous user's Macs. The active row is
    /// marked by each ``MobilePairedMac/isActive`` flag (the live connection's
    /// attach ticket carries a transient manual id, so it is not a reliable
    /// active marker on its own).
    public internal(set) var pairedMacs: [MobilePairedMac] = [] {
        didSet {
            guard oldValue.count != pairedMacs.count else { return }
            analytics.setSuperProperties(["paired_mac_count": .int(pairedMacs.count)])
        }
    }

    /// Per-surface output continuations for the libghostty render path. A mounted
    /// `GhosttySurfaceView` obtains a stream via ``terminalOutputStream(surfaceID:)``
    /// and receives VT patch bytes derived from render-grid frames. Raw PTY bytes
    /// flow through the same continuation as a compatibility fallback for older
    /// Mac hosts.
    var terminalByteContinuationsBySurfaceID: [String: AsyncStream<Data>.Continuation] = [:]

}

struct MobileTerminalViewportKey: Hashable, Sendable {
    var workspaceID: MobileWorkspacePreview.ID
    var terminalID: MobileTerminalPreview.ID
}

struct MobileManualAttachTicketCreateResponse: Decodable, Sendable {
    var ticket: CmxAttachTicket

    static func decode(_ data: Data) throws -> MobileManualAttachTicketCreateResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MobileManualAttachTicketCreateResponse.self, from: data)
    }
}

extension CmxAttachTicket {
    func constrainingRoutes(
        to routes: [CmxAttachRoute],
        fallbackDisplayName: String
    ) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: workspaceID,
            terminalID: terminalID,
            macDeviceID: macDeviceID,
            macDisplayName: macDisplayName ?? fallbackDisplayName,
            routes: routes,
            expiresAt: expiresAt,
            authToken: authToken
        )
    }

}

extension MobileWorkspacePreview {
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
