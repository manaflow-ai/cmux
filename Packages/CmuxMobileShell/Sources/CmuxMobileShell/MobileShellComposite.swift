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
                return ["workspace.updated", "terminal.render_grid"]
            case .rawBytes:
                return ["workspace.updated", "terminal.bytes"]
            }
        }
    }

    private static let hasKnownPairedMacDefaultsKey = "cmux.mobile.hasKnownPairedMac"

    private static let terminalRenderGridCapability = "terminal.render_grid.v1"
    private static let workspaceActionsCapability = "workspace.actions.v1"
    private static let terminalOutputCapabilityTimeoutNanoseconds: UInt64 = 750_000_000

    /// How long the render-grid stream may stay silent (no event of any topic)
    /// before the liveness watchdog assumes the push subscription is dead and
    /// forces a re-subscribe + replay. Picked at the low end of the acceptable
    /// 8-12s window so a wedged stream recovers in a few seconds instead of the
    /// transport's ~85s timeout, while staying well above any normal inter-event
    /// gap on a busy shell.
    private static let renderGridLivenessSilenceThreshold: TimeInterval = 9
    /// Cadence of the liveness watchdog tick. It only reads a timestamp and
    /// compares against the threshold, so a short interval is cheap; it does not
    /// reschedule per received event (an actively-streaming connection just keeps
    /// failing the silence check because `lastTerminalEventAt` stays fresh).
    private static let renderGridLivenessCheckInterval: TimeInterval = 2.5

    public private(set) var isSignedIn: Bool
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
    public var workspaces: [MobileWorkspacePreview]
    /// Whether the connected Mac advertises the `workspace.actions.v1` capability
    /// (rename/pin over the mobile RPC). `false` until host status is read, and
    /// for older Macs that lack the handler, so the UI can hide rename/pin rather
    /// than offer actions that would fail with `method_not_found`.
    public private(set) var supportsWorkspaceActions: Bool = false
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
    private var terminalAutoFocusSuppressedSurfaceIDs: Set<String> = []

    private let runtime: (any MobileSyncRuntime)?
    private let pairedMacStore: (any MobilePairedMacStoring)?
    private let identityProvider: (any MobileIdentityProviding)?
    private let reachability: any ReachabilityProviding
    private let pairingHintDefaults: UserDefaults
    private let clientID: String
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
    private var remoteClient: MobileCoreRPCClient? {
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
    // Liveness watchdog for the render-grid push subscription. The `for await`
    // listener loop blocks indefinitely if the underlying connection half-dies
    // (network blip, Mac stops pushing, background/foreground cycle): the
    // AsyncStream neither yields a new event nor finishes, so the loop sits
    // silent and the phone shows a stale frame while the Mac advances thousands
    // of render-grid deltas. The transport's own timeout (~85s) is far too slow.
    // A `DispatchSourceTimer` ticks independently of the (potentially wedged)
    // stream and compares "now" against the last received event to detect
    // prolonged silence, then tears down + re-subscribes + replays.
    private var renderGridLivenessTimer: (any DispatchSourceTimer)?
    private var renderGridLivenessListenerID: UUID?
    private var lastTerminalEventAt: Date?
    private var terminalSubscriptionRefreshTask: Task<Void, Never>?
    private var createWorkspaceTask: Task<Void, Never>?
    private var createTerminalTask: Task<Void, Never>?
    private var workspaceListRefreshTask: Task<Void, Never>?
    private var createWorkspaceTaskID: UUID?
    private var createTerminalTaskID: UUID?
    private var connectionGeneration: UUID
    private var reportedViewportSizesByTerminalKey: [MobileTerminalViewportKey: MobileTerminalViewportSize]
    private var deliveredTerminalByteEndSeqBySurfaceID: [String: UInt64]
    private var pendingTerminalByteEndSeqBySurfaceID: [String: UInt64]
    private var terminalReplaySurfaceIDsInFlight: Set<String>
    private var terminalOutputTransport: TerminalOutputTransport
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

    public init(
        runtime: (any MobileSyncRuntime)? = nil,
        isSignedIn: Bool = false,
        connectionState: MobileConnectionState = .disconnected,
        connectedHostName: String = "",
        pairingCode: String = "",
        workspaces: [MobileWorkspacePreview] = [],
        pairedMacStore: (any MobilePairedMacStoring)? = nil,
        clientIDRepository: MobileClientIDRepository = MobileClientIDRepository(defaults: .standard),
        identityProvider: (any MobileIdentityProviding)? = nil,
        reachability: any ReachabilityProviding = ReachabilityService(),
        pairingHintDefaults: UserDefaults = .standard,
        analytics: any AnalyticsEmitting = NoopAnalytics()
    ) {
        self.runtime = runtime
        self.pairedMacStore = pairedMacStore
        self.identityProvider = identityProvider
        self.reachability = reachability
        self.pairingHintDefaults = pairingHintDefaults
        self.analytics = analytics
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

    public func signIn() {
        let wasSignedIn = isSignedIn
        isSignedIn = true
        connectionError = nil
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
        pairingAttemptID = UUID()
        connectionGeneration = UUID()
        isSignedIn = false
        connectionState = .disconnected
        macConnectionStatus = .unavailable
        connectedHostName = ""
        pairingCode = ""
        terminalInputText = ""
        connectionError = nil
        activeTicket = nil
        activeRoute = nil
        // Drop the cached paired Macs so the next signed-in user never sees the
        // previous user's hosts in the switcher.
        pairedMacs = []
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
        selectedWorkspaceID = workspaces.first?.id
        selectedTerminalID = workspaces.first?.terminals.first?.id
    }

    public func resumeForegroundRefresh() {
        startObservingNetworkPathChanges()
        resyncTerminalOutput(reason: "foreground", restartEventStream: true)
    }

    /// Forward a scroll gesture to the Mac's real surface. libghostty does the
    /// mode-correct thing: normal screen moves the viewport into scrollback;
    /// alt screen + mouse reporting encodes mouse-wheel to the PTY for the
    /// program. The render-grid mirrors the result (it exports the live
    /// `vp_top`), so no local-mirror scroll or scrollback cache is needed.
    /// Fire-and-forget (called per display-link frame during a drag).
    public func scrollTerminal(surfaceID: String, lines: Double, col: Int, row: Int) async {
        guard lines != 0,
              let client = remoteClient,
              let workspaceID = workspaceID(forTerminalID: surfaceID) else {
            return
        }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.terminal.scroll",
                params: [
                    "workspace_id": workspaceID.rawValue,
                    "surface_id": surfaceID,
                    "client_id": clientID,
                    "delta_lines": lines,
                    "col": col,
                    "row": row,
                ]
            )
            _ = try await client.sendRequest(request)
        } catch {
            mobileShellLog.error("scroll forward failed surface=\(surfaceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
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

    // MARK: - Workspace actions

    /// Rename a workspace on the Mac.
    ///
    /// Fire-and-forget against the authoritative state: the Mac applies the title
    /// and its workspace-list observer pushes `workspace.updated`, which refreshes
    /// this list. No local optimistic mutation, so overlapping actions can never
    /// leave stale state.
    /// - Parameters:
    ///   - id: The workspace to rename.
    ///   - title: The new title. Whitespace-only titles are ignored.
    public func renameWorkspace(id: MobileWorkspacePreview.ID, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let client = remoteClient else { return }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "workspace.action",
                params: [
                    "workspace_id": id.rawValue,
                    "action": "rename",
                    "title": trimmed,
                    "client_id": clientID,
                ]
            )
            _ = try await client.sendRequest(request)
        } catch {
            mobileShellLog.error("workspace rename failed id=\(id.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    /// Pin or unpin a workspace on the Mac.
    ///
    /// Fire-and-forget against the authoritative state: the Mac toggles the pin
    /// and its workspace-list observer (which watches `$isPinned`) pushes
    /// `workspace.updated`, which refreshes this list. No local optimistic
    /// mutation, so overlapping pin/unpin taps can never leave stale state.
    /// - Parameters:
    ///   - id: The workspace to pin or unpin.
    ///   - pinned: `true` to pin, `false` to unpin.
    public func setWorkspacePinned(id: MobileWorkspacePreview.ID, _ pinned: Bool) async {
        guard let client = remoteClient else { return }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "workspace.action",
                params: [
                    "workspace_id": id.rawValue,
                    "action": pinned ? "pin" : "unpin",
                    "client_id": clientID,
                ]
            )
            _ = try await client.sendRequest(request)
        } catch {
            mobileShellLog.error("workspace pin failed id=\(id.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
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
        var description: String {
            switch self {
            case .networkChange: return "networkChange"
            case .manual: return "manual"
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
        connectionError = nil
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
        do {
            let ticket = try await manualHostTicket(
                name: trimmedName,
                host: normalizedHost,
                port: port
            )
            guard isCurrentPairingAttempt(attemptID) else { return }
            try await connect(ticket: ticket, allowsStackAuthFallback: true)
            guard isCurrentPairingAttempt(attemptID) else { return }
            if connectionState == .connected {
                recordPairingSucceeded()
            } else {
                recordPairingFailed(reason: "other", phase: "connect")
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
                recordPairingFailed(reason: "account_mismatch", phase: "auth")
                return
            }
            recordPairingFailed(reason: Self.pairingFailureReason(for: error), phase: "connect")
            connectionError = Self.localizedConnectionError(for: error, route: activeRoute ?? directRoute)
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
        await connectManualHost(name: mac.displayName ?? host, host: host, port: port)
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

    private func persistPairedMacFromTicket(_ ticket: CmxAttachTicket) async {
        guard let pairedMacStore else { return }
        guard !ticket.macDeviceID.isEmpty else { return }
        // Strip routes that we can't reconnect to without server-side state
        // (manual-workspace routes have no real macDeviceID and aren't useful).
        guard ticket.macDeviceID != "manual-ticket-request",
              !ticket.macDeviceID.hasPrefix("manual-") else { return }
        let stackUserID = identityProvider?.currentUserID
        do {
            try await pairedMacStore.upsert(
                macDeviceID: ticket.macDeviceID,
                displayName: ticket.macDisplayName,
                routes: ticket.routes,
                markActive: true,
                stackUserID: stackUserID
            )
            // A real, reconnectable Mac is now the active paired Mac: record the
            // persisted hint so the next launch shows RestoringSessionView during
            // the reconnect window instead of the empty add-device sheet.
            hasKnownPairedMac = true
        } catch {
            mobileShellLog.error("paired mac store upsert failed: \(String(describing: error), privacy: .public)")
        }
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
        let rawURL = Self.normalizedPairingURL(rawValue ?? pairingCode)
        let attemptID = beginPairingAttempt(method: "qr")
        let ticket: CmxAttachTicket
        do {
            ticket = try CmxAttachTicketInput.decode(rawURL)
        } catch {
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            connectionError = L10n.string("mobile.pairing.invalidCode", defaultValue: "Invalid pairing code.")
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
            recordPairingFailed(reason: "invalid_code", phase: "validation")
            return .failed
        }

        do {
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            try await connect(ticket: ticket)
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            if connectionState == .connected && activeTicket != nil {
                recordPairingSucceeded()
                return .connected
            }
            recordPairingFailed(reason: "other", phase: "connect")
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
            // Surface a definitive auth failure as a re-auth prompt rather than a
            // generic connection error (matches the manual-host path).
            if disconnectForAuthorizationFailureIfNeeded(error) {
                recordPairingFailed(reason: "account_mismatch", phase: "auth")
                return .failed
            }
            recordPairingFailed(reason: Self.pairingFailureReason(for: error), phase: "connect")
            connectionError = Self.localizedConnectionError(for: error, route: activeRoute)
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
            return .failed
        }
    }

    public func cancelPairing() {
        pairingAttemptID = UUID()
        connectionError = nil
        connectionState = .disconnected
        macConnectionStatus = .unavailable
        clearRemoteConnectionContext()
    }

    /// Tear down the live connection and reset connection UI state, without
    /// touching the paired-Mac store or the restoring-gate hint. The switcher's
    /// ``forgetMac(macDeviceID:)`` and ``switchToMac(macDeviceID:)`` reuse this,
    /// so it must not clear ``hasKnownPairedMac`` (that belongs to the explicit
    /// forget-active path below).
    private func disconnectLiveConnection() {
        suppressNextConnectionOutageEdge = true
        pairingAttemptID = UUID()
        connectionError = nil
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

    private func connect(
        ticket: CmxAttachTicket,
        allowsStackAuthFallback: Bool? = nil
    ) async throws {
        let generation = UUID()
        connectionGeneration = generation
        cancelRemoteOperationTasks()
        rawTerminalInputBuffer.clear()
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        let supportedRoutes = Self.supportedRoutes(for: ticket, supportedKinds: supportedKinds)
        guard let firstRoute = supportedRoutes.first else {
            connectionError = L10n.string("mobile.pairing.unsupportedRoute", defaultValue: "This pairing code is not supported.")
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
            return
        }
        guard Self.attachTicketIsUnexpired(ticket, now: runtime?.now() ?? Date()) else {
            connectionError = Self.localizedConnectionError(for: MobileShellConnectionError.attachTicketExpired, route: firstRoute)
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
            throw MobileShellConnectionError.attachTicketExpired
        }

        activeTicket = ticket
        activeRoute = firstRoute
        connectedHostName = ticket.macDisplayName ?? ticket.macDeviceID
        replaceRemoteClient(with: nil)

        guard let runtime else {
            guard generation == connectionGeneration else { return }
            connectionError = nil
            applyPreviewTicket(ticket, route: firstRoute)
            connectionState = .connected
            markMacConnectionHealthy()
            return
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
                    guard generation == connectionGeneration, isSignedIn else { return }
                    replaceRemoteClient(with: client)
                    startTerminalRefreshPolling()
                    connectionError = nil
                    await persistPairedMacFromTicket(ticket)
                    applyRemoteWorkspaceList(response, preferActiveTicketTarget: workspaceListRequest.preferActiveTicketTarget)
                    syncSelectedTerminalForWorkspace()
                    connectionState = .connected
                    markMacConnectionHealthy()
                    if workspaceListRequest.isScoped {
                        scheduleFullWorkspaceListRefreshIfAvailable(
                            client: client,
                            route: route,
                            generation: generation
                        )
                    }
                    return
                } catch {
                    lastError = error
                    guard generation == connectionGeneration, isSignedIn else { return }
                    mobileShellLog.error(
                        "pairing route failed kind=\(route.kind.rawValue, privacy: .public) endpoint=\(route.endpoint.logDescription, privacy: .private) scoped=\(workspaceListRequest.isScoped ? 1 : 0, privacy: .public): \(String(describing: error), privacy: .private)"
                    )
                }
            }
        }

        clearRemoteConnectionContext()
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
        ticket.expiresAt > now
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
    }

    private func resetTerminalOutputTracking() {
        deliveredTerminalByteEndSeqBySurfaceID = [:]
        pendingTerminalByteEndSeqBySurfaceID = [:]
        terminalReplaySurfaceIDsInFlight = []
        terminalOutputTransport = .rawBytes
        supportsWorkspaceActions = false
        terminalSubscriptionRefreshTask?.cancel()
        terminalSubscriptionRefreshTask = nil
        stopRenderGridLivenessWatchdog(listenerID: nil)
        lastTerminalEventAt = nil
    }

    /// The one shared entry every pairing flow funnels through, so it is also the
    /// single `ios_pairing_started` fire-site. `method` is `qr`/`manual`/
    /// `attach_url`; pass `nil` for non-instrumented internal flows (preview).
    private func beginPairingAttempt(method: String? = nil) -> UUID {
        let attemptID = UUID()
        pairingAttemptID = attemptID
        connectionGeneration = UUID()
        cancelRemoteOperationTasks()
        rawTerminalInputBuffer.clear()
        connectionError = nil
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

    private func markMacConnectionUnavailableIfNeeded(after error: Error) {
        guard Self.isMacAvailabilityFailure(error) else { return }
        markMacConnectionUnavailable()
    }

    private static func isMacAvailabilityFailure(_ error: Error) -> Bool {
        if error is CmxNetworkByteTransportError {
            return true
        }
        guard let shellError = error as? MobileShellConnectionError else {
            return false
        }
        switch shellError {
        case .connectionClosed, .requestTimedOut:
            return true
        case .invalidResponse, .insecureManualRoute, .attachTicketExpired, .authorizationFailed, .accountMismatch, .rpcError:
            // .accountMismatch means the Mac is reachable but signed in to a
            // different account; that is an auth problem, not a Mac-availability one.
            return false
        }
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
            connectionError = Self.localizedConnectionError(for: error)
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
            connectionError = Self.localizedConnectionError(for: error)
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
            connectionError = Self.localizedConnectionError(for: error)
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
            connectionError = Self.localizedConnectionError(for: error)
        }
    }

    private var terminalEventStreamID: String {
        "ios-terminal-events-\(clientID)"
    }

    private func requestTerminalEventSubscription(
        client: MobileCoreRPCClient,
        reason: String,
        topics: [String]
    ) async -> Bool {
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
            return false
        }
        let responseData: Data
        do {
            responseData = try await client.sendRequest(requestData)
        } catch {
            mobileShellLog.error("subscribe failed reason=\(reason, privacy: .public): \(String(describing: error), privacy: .private)")
            // Event-stream (re)subscribe is the view-only/foreground-resume path.
            // A definitive auth failure here (RPC layer already tried a
            // force-refresh + retry) must drive the re-auth prompt instead of a
            // silently stale live frame.
            if remoteClient === client {
                _ = disconnectForAuthorizationFailureIfNeeded(error)
            }
            return false
        }
        let response = try? MobileEventSubscribeResponse.decode(responseData)
        guard let streamID = response?.streamID, !streamID.isEmpty else {
            mobileShellLog.error("subscribe response missing stream_id reason=\(reason, privacy: .public)")
            return false
        }
        #if DEBUG
        mobileShellLog.info("subscribe active reason=\(reason, privacy: .public) streamID=\(streamID, privacy: .public)")
        #endif
        return true
    }

    private func resolveTerminalOutputTransport(client: MobileCoreRPCClient) async -> TerminalOutputTransport {
        let fallback: TerminalOutputTransport = .rawBytes
        do {
            let data = try await client.sendRequest(
                MobileCoreRPCClient.requestData(method: "mobile.host.status", params: [:]),
                timeoutNanoseconds: Self.terminalOutputCapabilityTimeoutNanoseconds
            )
            guard let payload = try? MobileHostStatusResponse.decode(data) else {
                terminalOutputTransport = fallback
                supportsWorkspaceActions = false
                return fallback
            }
            supportsWorkspaceActions = payload.capabilities.contains(Self.workspaceActionsCapability)
            let transport: TerminalOutputTransport = payload.capabilities.contains(Self.terminalRenderGridCapability) ||
                payload.terminalFidelity == "render_grid" ? .renderGrid : .rawBytes
            terminalOutputTransport = transport
            MobileDebugLog.anchormux("sync.transport=\(transport == .renderGrid ? "render_grid" : "raw_bytes")")
            return transport
        } catch {
            terminalOutputTransport = fallback
            supportsWorkspaceActions = false
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
            let subscribed = await self?.requestTerminalEventSubscription(
                client: client,
                reason: "start",
                topics: topics
            ) ?? false
            guard subscribed else {
                MobileDebugLog.anchormux("sync.subscribe_failed reason=start")
                self?.markMacConnectionUnavailable()
                return
            }
            self?.markMacConnectionHealthy()
            MobileDebugLog.anchormux("sync.subscribe_ok topics=\(topics.count) transport=\(outputTransport)")
            // Keep the listener alive without keeping the shell store alive.
            for await event in stream {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard self.remoteClient === client, self.connectionState == .connected else { return }
                // Any yielded envelope proves the transport is still pushing, so
                // it resets the liveness window (not just render_grid events).
                self.lastTerminalEventAt = self.runtime?.now() ?? Date()
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
                }
            }
            guard let self else { return }
            self.handleTerminalEventStreamEnded(listenerID: listenerID, client: client)
        }
    }

    private func handleTerminalEventStreamEnded(listenerID: UUID, client: MobileCoreRPCClient) {
        guard !Task.isCancelled,
              terminalEventListenerID == listenerID,
              remoteClient === client,
              connectionState == .connected else {
            return
        }
        mobileShellLog.info("terminal event stream ended, restarting")
        MobileDebugLog.anchormux("sync.stream_ended restarting (render-grid push stopped; falling back to poll)")
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
    /// no-op, so an actively-streaming connection never triggers recovery; only a
    /// genuinely silent stream crosses the threshold.
    private func startRenderGridLivenessWatchdog(listenerID: UUID) {
        stopRenderGridLivenessWatchdog(listenerID: nil)
        renderGridLivenessListenerID = listenerID
        // Reset the window so a freshly-armed subscription gets the full silence
        // budget before it can be judged dead.
        lastTerminalEventAt = runtime?.now() ?? Date()
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
    }

    /// One watchdog tick on the main actor: if the subscription generation still
    /// matches, the store is connected, and the stream has been silent past the
    /// threshold, tear down + re-subscribe + replay via the existing resync path.
    private func checkRenderGridLiveness(listenerID: UUID) {
        guard renderGridLivenessListenerID == listenerID else { return }
        guard remoteClient != nil, connectionState == .connected else { return }
        guard terminalEventListenerID == listenerID else { return }
        let now = runtime?.now() ?? Date()
        let last = lastTerminalEventAt ?? now
        let silent = now.timeIntervalSince(last)
        guard silent >= Self.renderGridLivenessSilenceThreshold else { return }
        let silentMs = Int(silent * 1000)
        MobileDebugLog.anchormux("sync.liveness re-subscribe silentMs=\(silentMs)")
        mobileShellLog.info("render-grid stream silent for \(silentMs, privacy: .public)ms, re-subscribing")
        // resyncTerminalOutput(restartEventStream: true) stops the wedged listener
        // (which cancels this watchdog via stopTerminalRefreshPolling) and starts a
        // fresh subscription + watchdog, then replays every surface so the phone
        // catches up on the deltas it missed while the stream was silent.
        resyncTerminalOutput(reason: "liveness", restartEventStream: true)
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

    private static func terminalSnapshotReplacementBytes(_ snapshotBytes: Data) -> Data {
        var bytes = Data("\u{1B}c\u{1B}[H\u{1B}[2J\u{1B}[3J".utf8)
        bytes.append(snapshotBytes)
        return bytes
    }

    /// Per-surface output continuations for the libghostty render path. A mounted
    /// `GhosttySurfaceView` obtains a stream via ``terminalOutputStream(surfaceID:)``
    /// and receives VT patch bytes derived from render-grid frames. Raw PTY bytes
    /// flow through the same continuation as a compatibility fallback for older
    /// Mac hosts.
    private var terminalByteContinuationsBySurfaceID: [String: AsyncStream<Data>.Continuation] = [:]

    /// Yield a chunk of output bytes to the surface's stream, if one is attached.
    private func deliverTerminalBytes(_ bytes: Data, surfaceID: String) {
        terminalByteContinuationsBySurfaceID[surfaceID]?.yield(bytes)
    }

    /// Whether a surface currently has an attached output stream consumer.
    private func hasTerminalOutputSink(surfaceID: String) -> Bool {
        terminalByteContinuationsBySurfaceID[surfaceID] != nil
    }

    private func registerTerminalOutput(
        surfaceID: String,
        continuation: AsyncStream<Data>.Continuation
    ) {
        terminalByteContinuationsBySurfaceID[surfaceID] = continuation
        deliveredTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        pendingTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        #if DEBUG
        mobileShellLog.info("CMUX_REPLAY register sink surface=\(surfaceID, privacy: .public) connected=\(self.connectionState == .connected, privacy: .public) hasClient=\(self.remoteClient != nil, privacy: .public) workspaceCount=\(self.workspaces.count, privacy: .public)")
        #endif
        requestTerminalReplay(surfaceID: surfaceID)
    }

    private func unregisterTerminalOutput(surfaceID: String) {
        terminalByteContinuationsBySurfaceID.removeValue(forKey: surfaceID)
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
    public func terminalOutputStream(surfaceID: String) -> AsyncStream<Data> {
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
                    deliverBytes = renderGrid.vtPatchBytes()
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

    private func workspaceID(forTerminalID terminalID: String) -> MobileWorkspacePreview.ID? {
        for workspace in workspaces {
            if workspace.terminals.contains(where: { $0.id.rawValue == terminalID }) {
                return workspace.id
            }
        }
        return nil
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
        if let deliveredSeq = deliveredTerminalByteEndSeqBySurfaceID[renderGrid.surfaceID],
           deliveredSeq > renderGrid.stateSeq {
            MobileDebugLog.anchormux(
                "sync.render_grid_stale surface=\(renderGrid.surfaceID) delivered=\(deliveredSeq) frame=\(renderGrid.stateSeq)"
            )
            return
        }
        let bytes = renderGrid.vtPatchBytes()
        markTerminalBytesDelivered(surfaceID: renderGrid.surfaceID, endSeq: renderGrid.stateSeq)
        #if DEBUG
        mobileShellLog.info("CMUX_REPLAY live render_grid surface=\(renderGrid.surfaceID, privacy: .public) full=\(renderGrid.full, privacy: .public) spans=\(renderGrid.rowSpans.count, privacy: .public) cleared=\(renderGrid.clearedRows.count, privacy: .public) seq=\(renderGrid.stateSeq, privacy: .public) hasSink=true")
        #endif
        guard !bytes.isEmpty else { return }
        deliverTerminalBytes(bytes, surfaceID: renderGrid.surfaceID)
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
        guard let client = remoteClient else { return }
        workspaceListRefreshTask?.cancel()
        workspaceListRefreshTask = Task { @MainActor [weak self] in
            defer { self?.workspaceListRefreshTask = nil }
            guard let self else { return }
            do {
                let request = try MobileCoreRPCClient.requestData(method: "mobile.workspace.list", params: [:])
                let data = try await client.sendRequest(request)
                let response = try MobileSyncWorkspaceListResponse.decode(data)
                guard self.remoteClient === client, self.connectionState == .connected else { return }
                self.applyRemoteWorkspaceList(response, preferActiveTicketTarget: false)
                self.syncSelectedTerminalForWorkspace()
            } catch {
                mobileShellLog.error("workspace list event refresh failed: \(String(describing: error), privacy: .private)")
            }
        }
    }

    private func stopTerminalRefreshPolling() {
        terminalEventListenerTask?.cancel()
        terminalEventListenerTask = nil
        terminalEventListenerID = nil
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

    private func disconnectForAuthorizationFailureIfNeeded(_ error: any Error) -> Bool {
        guard Self.shouldDisconnectForAuthorizationFailure(error) else {
            return false
        }
        connectionError = Self.localizedConnectionError(for: error, route: activeRoute)
        connectionRequiresReauth = true
        connectionState = .disconnected
        macConnectionStatus = .unavailable
        clearRemoteConnectionContext()
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

    private static func localizedConnectionError(for error: any Error, route: CmxAttachRoute? = nil) -> String {
        let hostPort = route.flatMap(Self.hostPortDescription(for:))
        if let networkError = error as? CmxNetworkByteTransportError {
            switch networkError {
            case .connectionTimedOut:
                return localizedHostPortConnectionError(
                    key: "mobile.pairing.connectTimedOutFormat",
                    defaultValue: "No response from %@:%d. Your Mac may be asleep or off Tailscale. Make sure it's awake and on the same Tailscale network.",
                    fallbackKey: "mobile.pairing.runtimeUnavailable",
                    fallbackDefaultValue: "Could not connect to your computer.",
                    hostPort: hostPort
                )
            case let .connectionFailed(_, kind):
                switch kind {
                case .connectionRefused:
                    return L10n.string(
                        "mobile.pairing.appNotRunning",
                        defaultValue: "Your Mac is reachable, but cmux isn't running there (or mobile pairing is off). Open cmux on the Mac, then try again."
                    )
                case .permissionDenied:
                    return L10n.string(
                        "mobile.pairing.localNetworkPermission",
                        defaultValue: "iOS blocked the connection. Allow cmux to use the Local Network in iOS Settings, then try again."
                    )
                case .hostUnreachable:
                    return localizedHostPortConnectionError(
                        key: "mobile.pairing.hostUnreachableFormat",
                        defaultValue: "Can't reach %@:%d. Make sure your Mac is awake and on the same Tailscale network as this device.",
                        fallbackKey: "mobile.pairing.runtimeUnavailable",
                        fallbackDefaultValue: "Could not connect to your computer.",
                        hostPort: hostPort
                    )
                case .dnsFailed:
                    return localizedHostPortConnectionError(
                        key: "mobile.pairing.dnsFailedFormat",
                        defaultValue: "Couldn't resolve %@. Check that Tailscale is connected on both devices.",
                        fallbackKey: "mobile.pairing.runtimeUnavailable",
                        fallbackDefaultValue: "Could not connect to your computer.",
                        hostPort: hostPort
                    )
                case .timedOut, .secureChannelFailed, .generic:
                    return localizedHostPortConnectionError(
                        key: "mobile.pairing.connectionFailedFormat",
                        defaultValue: "Could not reach %@:%d. Check that the host is reachable over Tailscale or LAN and that the port is correct.",
                        fallbackKey: "mobile.pairing.runtimeUnavailable",
                        fallbackDefaultValue: "Could not connect to your computer.",
                        hostPort: hostPort
                    )
                }
            case .notConnected, .alreadyClosed:
                return localizedHostPortConnectionError(
                    key: "mobile.pairing.connectionFailedFormat",
                    defaultValue: "Could not reach %@:%d. Check that the host is reachable over Tailscale or LAN and that the port is correct.",
                    fallbackKey: "mobile.pairing.runtimeUnavailable",
                    fallbackDefaultValue: "Could not connect to your computer.",
                    hostPort: hostPort
                )
            case .receiveFailed, .sendFailed:
                return localizedHostPortConnectionError(
                    key: "mobile.pairing.connectionDroppedFormat",
                    defaultValue: "Connected to %@:%d, but the host closed the connection. Check that the host app is still running.",
                    fallbackKey: "mobile.pairing.runtimeUnavailable",
                    fallbackDefaultValue: "Could not connect to your computer.",
                    hostPort: hostPort
                )
            case .emptyHost, .invalidPort, .invalidMaximumReceiveLength, .unsupportedRouteKind, .unsupportedEndpoint, .receiveAlreadyInProgress, .sendAlreadyInProgress:
                break
            }
        }
        guard let connectionError = error as? MobileShellConnectionError else {
            return L10n.string("mobile.pairing.runtimeUnavailable", defaultValue: "Could not connect to your computer.")
        }
        switch connectionError {
        case .requestTimedOut:
            return localizedHostPortConnectionError(
                key: "mobile.pairing.connectionTimedOutFormat",
                defaultValue: "No response from %@:%d. Make sure the host app is open and accepting mobile connections.",
                fallbackKey: "mobile.pairing.requestTimedOut",
                fallbackDefaultValue: "The computer did not respond. Check the host and port, then try again.",
                hostPort: hostPort
            )
        case .insecureManualRoute:
            return L10n.string("mobile.pairing.secureRouteRequired", defaultValue: "This pairing route is not allowed. Enter a host and port, or pair with a QR/link from that computer.")
        case .attachTicketExpired:
            return L10n.string("mobile.pairing.attachTicketExpired", defaultValue: "This pairing link expired. Pair again with a fresh QR/link from that computer.")
        case .authorizationFailed:
            return L10n.string("mobile.pairing.authorizationFailed", defaultValue: "Couldn't verify your account with this Mac. Make sure both devices use the same cmux account and a matching build (both release, or both development), then try again.")
        case .accountMismatch:
            return L10n.string("mobile.pairing.accountMismatch", defaultValue: "This Mac is signed in to a different cmux account. Sign out and sign back in with the account that owns this Mac.")
        case .invalidResponse, .connectionClosed, .rpcError:
            return L10n.string("mobile.pairing.runtimeUnavailable", defaultValue: "Could not connect to your computer.")
        }
    }

    /// Maps a connect error to the `ios_pairing_failed` `reason` enum (sizes and
    /// enums only — never the underlying error text). Falls back to `network` for
    /// transport drops and `other` for anything unrecognized.
    private static func pairingFailureReason(for error: any Error) -> String {
        if let connectionError = error as? MobileShellConnectionError {
            switch connectionError {
            case .attachTicketExpired: return "ticket_expired"
            case .authorizationFailed: return "auth"
            case .accountMismatch: return "account_mismatch"
            case .insecureManualRoute: return "unsupported_route"
            case .requestTimedOut: return "timeout"
            case .invalidResponse, .connectionClosed, .rpcError: return "network"
            }
        }
        if error is CancellationError { return "cancelled" }
        return "other"
    }

    private static func localizedHostPortConnectionError(
        key: StaticString,
        defaultValue: String.LocalizationValue,
        fallbackKey: StaticString,
        fallbackDefaultValue: String.LocalizationValue,
        hostPort: (host: String, port: Int)?
    ) -> String {
        guard let hostPort else {
            return L10n.string(fallbackKey, defaultValue: fallbackDefaultValue)
        }
        return String(
            format: L10n.string(key, defaultValue: defaultValue),
            hostPort.host,
            hostPort.port
        )
    }

    private static func hostPortDescription(for route: CmxAttachRoute) -> (host: String, port: Int)? {
        guard case let .hostPort(host, port) = route.endpoint else {
            return nil
        }
        return (host, port)
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
