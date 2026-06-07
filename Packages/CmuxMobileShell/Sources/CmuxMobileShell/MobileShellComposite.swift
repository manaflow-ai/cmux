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
    public private(set) var connectionState: MobileConnectionState
    /// The live heavy-session health of the **active** Mac (the one the live
    /// render-grid/input pipeline targets), kept for back-compat with the
    /// recovery banner and detail chrome. Mirrored into the active Mac's entry of
    /// ``macStatusByMac`` so the grouped list shows the same status on that Mac's
    /// section. Per-Mac status for the others comes from ``macStatus(forMacDeviceID:)``.
    public private(set) var macConnectionStatus: MobileMacConnectionStatus {
        didSet {
            if let activeMacDeviceID {
                macStatusByMac[activeMacDeviceID] = macConnectionStatus
            }
        }
    }
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

    // MARK: - Aggregated multi-Mac workspace partitions

    /// Workspaces partitioned by the paired Mac they were sourced from.
    ///
    /// The aggregated all-devices list is the union of every paired Mac's
    /// workspaces. Each Mac owns its own partition, so a workspace-list refresh
    /// for one Mac (the live heavy session, or a transient `workspace.list`)
    /// must replace **only that Mac's partition** and never clobber the others.
    private var workspacesByMac: [String: [MobileWorkspacePreview]] = [:]

    /// Per-Mac connectivity, surfaced as row/section metadata in the list.
    ///
    /// Only the active (heavy-session) Mac advances through `.reconnecting`; the
    /// others are `.connected` when a recent `workspace.list` succeeded and
    /// `.unavailable` when the Mac was unreachable on the last refresh.
    private var macStatusByMac: [String: MobileMacConnectionStatus] = [:]

    /// Stable display order of Mac device ids in the aggregated list.
    ///
    /// Preserves first-seen order so the flattened ``workspaces`` and the
    /// grouped UI sections do not reshuffle as partitions update.
    private var macOrder: [String] = []

    /// Display names for Mac device ids, for the per-Mac section headers.
    private var macDisplayNameByMac: [String: String] = [:]

    /// The paired Mac the live heavy session (render-grid + input + replay +
    /// viewport + liveness watchdog) currently targets.
    ///
    /// `remoteClient` is always this Mac's client. Routing resolves a surface to
    /// its owning Mac and only touches `remoteClient` when that Mac is this one,
    /// so input/replay/viewport can never reach a different Mac's session.
    private var activeMacDeviceID: String?

    /// The aggregated, device-ordered union of every paired Mac's workspaces.
    ///
    /// Derived from ``workspacesByMac`` in ``macOrder`` so consumers (the list,
    /// selection, lookups) see one stable flattened view. Writes go through the
    /// partition-scoped setters, never this projection.
    public var workspaces: [MobileWorkspacePreview] {
        macOrder.flatMap { workspacesByMac[$0] ?? [] }
    }

    /// Value snapshots of the aggregated list, grouped by source Mac.
    ///
    /// Each section carries the device identity, display name, connectivity
    /// status, active flag, and that Mac's workspaces, with no reference back to
    /// this store. The grouped list view binds to these snapshots so its rows and
    /// section headers stay below the list's snapshot boundary. Ordered by
    /// ``macOrder`` (first-seen), then any paired Mac not yet partitioned, so
    /// sections do not reshuffle as partitions update. A section is emitted for
    /// every such Mac — including a paired-but-offline Mac with no cached
    /// workspaces (an empty grayed section) — so an offline cold launch shows the
    /// device rather than an empty shell. A forgotten Mac is removed from both
    /// ``macOrder`` and ``pairedMacs``, so it still drops out.
    public var deviceSections: [MobileWorkspaceDeviceSection] {
        // Paired Macs not yet in macOrder (a cold launch before the first refresh
        // marks them) still get a grayed section so the user sees the device.
        let extraPairedMacIDs = pairedMacs
            .map(\.macDeviceID)
            .filter { !macOrder.contains($0) && $0 != PreviewMobileHost.deviceID }
        let orderedMacIDs = macOrder + extraPairedMacIDs
        return orderedMacIDs.map { macID in
            MobileWorkspaceDeviceSection(
                deviceID: macID,
                displayName: macDisplayName(forMacDeviceID: macID),
                status: macStatus(forMacDeviceID: macID),
                isActive: macID == activeMacDeviceID,
                workspaces: workspacesByMac[macID] ?? []
            )
        }
    }

    /// Whether the connected Mac advertises the `workspace.actions.v1` capability
    /// (rename/pin over the mobile RPC). `false` until host status is read, and
    /// for older Macs that lack the handler, so the UI can hide rename/pin rather
    /// than offer actions that would fail with `method_not_found`.
    public private(set) var supportsWorkspaceActions: Bool = false
    public var terminalInputText: String
    public var selectedWorkspaceID: MobileWorkspacePreview.ID? {
        didSet {
            reconcileSelectedMacForSelectedWorkspace(previousMacDeviceID: selectedMacDeviceID)
            syncSelectedTerminalForWorkspace()
        }
    }

    /// The paired Mac that owns the currently selected workspace.
    ///
    /// Selection is `(macDeviceID, workspaceID)`: because workspace ids are only
    /// unique within a Mac, the selected Mac disambiguates which partition the
    /// selection lives in and which Mac the heavy session must target. Kept in
    /// sync by the ``selectedWorkspaceID`` `didSet`; changing it retargets the
    /// heavy session to the new Mac.
    public private(set) var selectedMacDeviceID: String?

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
    /// In-flight on-demand refresh of the non-active Macs' list partitions via
    /// transient `workspace.list` clients. Coalesced (one at a time) and
    /// cancelled on sign-out so a slow fan-out can never write a stale partition.
    private var allMacsWorkspaceListRefreshTask: Task<Void, Never>?
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

    /// Whether the local synthetic create paths are valid (no real backend).
    ///
    /// ``createWorkspace`` / ``createTerminal`` synthesize a local workspace only
    /// when there is no real session to create against. Two cases qualify: a
    /// runtime-less store (SwiftUI previews, tests, the `preview()` factory), and
    /// the production legacy preview-host pairing-code path that makes the
    /// synthetic preview Mac the active device. A real session that is merely
    /// disconnected (`runtime != nil`, active Mac dropped or a real device) is
    /// **excluded**, so creation there is a no-op instead of injecting a fake
    /// preview workspace into the signed-in user's real device list.
    private var isPreviewHostActive: Bool {
        runtime == nil || activeMacDeviceID == PreviewMobileHost.deviceID
    }

    public var selectedWorkspace: MobileWorkspacePreview? {
        guard let selectedWorkspaceID else {
            return workspaces.first
        }
        // Resolve inside the selected Mac's partition first, since workspace ids
        // are only unique within a Mac and two Macs can collide. Fall back to a
        // cross-Mac match, then to the first workspace, so a selection that has
        // not yet been mac-tagged (or a drifted selection) still resolves.
        if let selectedMacDeviceID,
           let workspace = workspacesByMac[selectedMacDeviceID]?
            .first(where: { $0.id == selectedWorkspaceID }) {
            return workspace
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

    /// The selection-keyed send target `(workspace, terminal)`, but **only** when
    /// the selected workspace's Mac is the active heavy-session Mac.
    ///
    /// The composer/paste paths route by current selection rather than by a
    /// surface id, so during a heavy-session retarget (selection on Mac B,
    /// `remoteClient` still A's) they could otherwise send B's ids to A's client.
    /// This returns `nil` in that window, making such a send a safe no-op until
    /// the retarget completes, the same routing safety the surface-keyed paths
    /// get from ``workspaceID(forTerminalID:)``.
    private var activeSelectedSendTarget: (workspaceID: MobileWorkspacePreview.ID, terminalID: MobileTerminalPreview.ID)? {
        guard let activeMacDeviceID, selectedMacDeviceID == activeMacDeviceID else { return nil }
        guard let workspace = workspacesByMac[activeMacDeviceID]?
            .first(where: { $0.id == selectedWorkspaceID }) ?? workspacesByMac[activeMacDeviceID]?.first else {
            return nil
        }
        let terminalID: MobileTerminalPreview.ID
        if let selectedTerminalID,
           workspace.terminals.contains(where: { $0.id == selectedTerminalID }) {
            terminalID = selectedTerminalID
        } else if let preferred = workspace.preferredTerminal?.id {
            terminalID = preferred
        } else {
            return nil
        }
        return (workspace.id, terminalID)
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
        pairingHintDefaults: UserDefaults = .standard
    ) {
        self.runtime = runtime
        self.pairedMacStore = pairedMacStore
        self.identityProvider = identityProvider
        self.reachability = reachability
        self.pairingHintDefaults = pairingHintDefaults
        // Distinguish "key absent" (an install that predates the hint and may
        // already have a paired Mac in SQLite) from "key present and false" (we
        // determined there is no paired Mac). didSet is not called for these
        // initial assignments, so the undetermined flag is not clobbered here.
        self.pairedMacHintUndetermined = pairingHintDefaults.object(forKey: Self.hasKnownPairedMacDefaultsKey) == nil
        self.hasKnownPairedMac = pairingHintDefaults.bool(forKey: Self.hasKnownPairedMacDefaultsKey)
        self.clientID = clientIDRepository.clientID
        self.isSignedIn = isSignedIn
        self.connectionState = connectionState
        self.macConnectionStatus = connectionState == .connected ? .connected : .unavailable
        self.connectedHostName = connectedHostName
        self.pairingCode = pairingCode
        self.terminalInputText = ""
        self.connectionError = nil
        self.activeTicket = nil
        self.activeRoute = nil
        // `didSet` does not fire for the in-init assignment below, so seed the
        // partitions first and set the selected Mac explicitly to keep selection
        // consistent with the aggregated list from construction.
        let seed = Self.partitions(from: workspaces)
        self.workspacesByMac = seed.workspacesByMac
        self.macOrder = seed.macOrder
        self.macDisplayNameByMac = seed.displayNames
        self.macStatusByMac = [:]
        self.activeMacDeviceID = nil
        self.selectedMacDeviceID = workspaces.first?.sourceMacDeviceID
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
        allMacsWorkspaceListRefreshTask?.cancel()
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
        // Bootstrap the aggregated all-devices list on the first sign-in of this
        // session, independent of any foreground/reconnect path. This loads the
        // paired Macs (which sets `hasCompletedInitialPairedMacLoad`, so the root
        // gate can tell empty from still-loading) and pulls the non-active Macs'
        // lists so they appear grayed-or-live immediately. Idempotent: coalesced
        // by `refreshAllPairedMacWorkspaceLists`, and only kicked once per
        // sign-in transition so re-syncing an already-signed-in session is a no-op.
        guard !wasSignedIn else { return }
        // Claim this sign-in's generation. `signOut` bumps it, so a bootstrap that
        // started for a now-signed-out session bails before it can flip the
        // initial-load gate (whose reset `signOut` performed). Without this the
        // bootstrap's `loadPairedMacs` could take its `!isSignedIn` path and set
        // `hasCompletedInitialPairedMacLoad = true` after sign-out, making the next
        // sign-in evaluate `hasNoPairedMacs` before the new user's load resolves.
        signInBootstrapGeneration &+= 1
        let generation = signInBootstrapGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard generation == self.signInBootstrapGeneration, self.isSignedIn else { return }
            // loadPairedMacs first so `hasCompletedInitialPairedMacLoad` is set
            // even when no runtime/store is available to fan out the refresh,
            // letting the gate resolve empty-vs-loading on every path.
            await self.loadPairedMacs()
            guard generation == self.signInBootstrapGeneration, self.isSignedIn else { return }
            await self.refreshAllPairedMacWorkspaceLists()
        }
    }

    /// Monotonic generation for the ``signIn`` bootstrap task, bumped by
    /// ``signOut`` so a bootstrap from a now-signed-out session cannot resolve the
    /// initial-load gate for the next session.
    private var signInBootstrapGeneration = 0

    /// The real stored `macDeviceID` of a paired Mac currently being reconnected
    /// or switched to, so ``setActiveMac`` keys the live partition by the stored id
    /// even when a legacy host's synthetic ticket carries a `manual-...` id.
    ///
    /// Set by ``switchToMac`` / ``reconnectActiveMacIfAvailable`` around their
    /// ``connectManualHost`` call and consumed (cleared) by ``setActiveMac``. `nil`
    /// for first-time pairing / manual-host add / preview, which then key by the
    /// ticket as before. A transient rather than a threaded parameter so the public
    /// ``connectManualHost`` signature (used by the manual-add UI) is unchanged.
    private var pendingKnownActiveMacDeviceID: String?

    public func signOut() {
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
        // Re-arm the empty-vs-loading gate so the next sign-in re-resolves it, and
        // bump the sign-in bootstrap generation so an in-flight bootstrap from this
        // session can't flip the gate back to resolved after this reset.
        hasCompletedInitialPairedMacLoad = false
        signInBootstrapGeneration &+= 1
        // Reset the in-memory restoring flags; hasKnownPairedMac stays driven by
        // the forget path. On a real account switch the next reconnect's no-mac
        // branch clears the hint. Bump the reconnect generation so any in-flight
        // reconnect is superseded and can't re-set these flags after sign-out.
        storedMacReconnectGeneration &+= 1
        isReconnectingStoredMac = false
        didFinishStoredMacReconnectAttempt = false
        // Drop any queued heavy-session retarget so a pending switch can't fire
        // for the previous user after sign-out (the drain re-guards on pairedMacs).
        pendingHeavySessionTarget = nil
        replaceRemoteClient(with: nil)
        cancelRemoteOperationTasks()
        allMacsWorkspaceListRefreshTask?.cancel()
        allMacsWorkspaceListRefreshTask = nil
        rawTerminalInputBuffer.clear()
        reportedViewportSizesByTerminalKey = [:]
        // Drop every Mac's partition so a shared device never shows the previous
        // user's aggregated list. In a runtime-less SwiftUI preview, reseed the
        // synthetic preview host so previews still render content. In a production
        // session, clear to empty: reseeding the preview partition would survive
        // into the next user's signed-in session (the preview workspaces would
        // appear as a fake device section AND keep `hasNoPairedMacs` false, both
        // wrong for a real account).
        if runtime == nil {
            let seed = Self.partitions(from: PreviewMobileHost.workspaces)
            workspacesByMac = seed.workspacesByMac
            macOrder = seed.macOrder
            macDisplayNameByMac = seed.displayNames
            macStatusByMac = [:]
            selectedMacDeviceID = PreviewMobileHost.workspaces.first?.sourceMacDeviceID
            selectedWorkspaceID = PreviewMobileHost.workspaces.first?.id
            selectedTerminalID = PreviewMobileHost.workspaces.first?.terminals.first?.id
        } else {
            workspacesByMac = [:]
            macOrder = []
            macDisplayNameByMac = [:]
            macStatusByMac = [:]
            selectedMacDeviceID = nil
            selectedWorkspaceID = nil
            selectedTerminalID = nil
        }
        activeMacDeviceID = nil
    }

    public func resumeForegroundRefresh() {
        startObservingNetworkPathChanges()
        resyncTerminalOutput(reason: "foreground", restartEventStream: true)
        // Refresh the other Macs' list partitions on foreground so the
        // aggregated all-devices list reflects work done on those Macs while the
        // phone was backgrounded. The active Mac is refreshed by the live session.
        Task { @MainActor [weak self] in
            await self?.refreshAllPairedMacWorkspaceLists()
        }
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
        // workspace.action runs over the active Mac's client; only act on a
        // workspace that is in the active Mac's partition so a stale/non-active id
        // (or a cross-Mac id collision) can't mutate the wrong Mac's workspace.
        guard workspaceIsOnActiveMac(id) else { return }
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
        // Same active-Mac routing guard as `renameWorkspace`.
        guard workspaceIsOnActiveMac(id) else { return }
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
    public private(set) var connectionRecoveryFailed: Bool = false
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
        // The synthetic preview host owns the seeded preview-Mac partition, so
        // make it the active Mac and ensure that partition is populated (it may
        // have been cleared by a prior teardown). This keeps the preview create
        // paths routing into a real partition.
        activeMacDeviceID = PreviewMobileHost.deviceID
        if workspacesByMac[PreviewMobileHost.deviceID]?.isEmpty ?? true {
            setWorkspaces(
                PreviewMobileHost.workspaces,
                forMac: PreviewMobileHost.deviceID,
                displayName: PreviewMobileHost.hostName
            )
        }
        selectedMacDeviceID = PreviewMobileHost.deviceID
        connectionState = .connected
        markMacConnectionHealthy()
        if selectedWorkspaceID == nil {
            selectedWorkspaceID = workspacesByMac[PreviewMobileHost.deviceID]?.first?.id
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
            return
        }
        guard (1...65535).contains(port) else {
            connectionError = L10n.string("mobile.addDevice.invalidPort", defaultValue: "Enter a port from 1 to 65535.")
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
            return
        }

        let directRoute = try? Self.manualHostRoute(host: normalizedHost, port: port)
        let attemptID = beginPairingAttempt()
        do {
            let ticket = try await manualHostTicket(
                name: trimmedName,
                host: normalizedHost,
                port: port
            )
            guard isCurrentPairingAttempt(attemptID) else { return }
            try await connect(ticket: ticket, allowsStackAuthFallback: true)
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
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return }
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
        // Carry the real stored id so a legacy synthetic-ticket fallback still keys
        // the live partition by macDeviceID (matching pairedMacs / refresh / forget).
        pendingKnownActiveMacDeviceID = mac.macDeviceID
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
    public private(set) var pairedMacs: [MobilePairedMac] = []

    /// Reload ``pairedMacs`` from the store, scoped to the signed-in Stack user.
    ///
    /// A missing current Stack user id yields no pairings rather than falling
    /// back to the unscoped all-users query, so a shared device never exposes
    /// another user's Macs in the switcher.
    public func loadPairedMacs() async {
        guard let pairedMacStore, isSignedIn,
              let stackUserID = identityProvider?.currentUserID else {
            pairedMacs = []
            // No store / not signed in / no Stack user is a resolved "no Macs"
            // state, so the gate may now distinguish empty from still-loading.
            hasCompletedInitialPairedMacLoad = true
            return
        }
        let loaded: [MobilePairedMac]
        do {
            loaded = try await pairedMacStore.loadAll(stackUserID: stackUserID)
        } catch {
            mobileShellLog.error("paired mac store loadAll failed: \(String(describing: error), privacy: .public)")
            // Mark the initial load resolved even on failure so the root gate can
            // fall through to the pairing/disconnected flow (the safe state)
            // instead of stranding a signed-in user on an empty WorkspaceShellView
            // forever because `hasCompletedInitialPairedMacLoad` never flipped.
            // The existing partitions (if any) are preserved; only the gate
            // resolves. A later successful load repopulates `pairedMacs`.
            if isSignedIn, identityProvider?.currentUserID == stackUserID {
                hasCompletedInitialPairedMacLoad = true
            }
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
        // Seed display names for paired Macs so a not-yet-partitioned (offline)
        // Mac's grayed section shows its real name instead of the bare device id.
        for mac in loaded {
            if macDisplayNameByMac[mac.macDeviceID] == nil,
               let name = mac.displayName, !name.isEmpty {
                macDisplayNameByMac[mac.macDeviceID] = name
            }
        }
        hasCompletedInitialPairedMacLoad = true
    }

    /// Refresh the list partition of every **non-active** paired Mac on demand.
    ///
    /// The aggregated list is the union of every paired Mac's workspaces. The
    /// active Mac's partition is kept live by the heavy render-grid session, so
    /// it is excluded here. For each other reachable Mac this mints a fresh attach
    /// ticket, spins a transient ``MobileCoreRPCClient`` (no render-grid
    /// subscription), calls `workspace.list`, maps + tags the result into that
    /// Mac's partition, marks it `.connected`, then disconnects the transient
    /// client. An unreachable Mac is marked `.unavailable` and keeps its
    /// last-known partition (grayed) rather than disappearing.
    ///
    /// Phase 1 only: live secondary subscriptions are Phase 2. Coalesced (one
    /// fan-out at a time) and cancelled on sign-out. Each partition write is
    /// re-guarded after its `await` against sign-out / user-switch / mac-removal.
    public func refreshAllPairedMacWorkspaceLists() async {
        guard runtime != nil, pairedMacStore != nil, isSignedIn else { return }
        guard allMacsWorkspaceListRefreshTask == nil else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runAllPairedMacWorkspaceListRefresh()
        }
        allMacsWorkspaceListRefreshTask = task
        defer { allMacsWorkspaceListRefreshTask = nil }
        await task.value
    }

    private func runAllPairedMacWorkspaceListRefresh() async {
        await loadPairedMacs()
        guard let runtime, isSignedIn else { return }
        let stackUserID = identityProvider?.currentUserID
        let activeMac = activeMacDeviceID
        // Skip the active Mac (its partition is kept fresh by the live session)
        // and the synthetic preview Mac (no real route to dial).
        let targets = pairedMacs.filter { mac in
            mac.macDeviceID != activeMac && mac.macDeviceID != PreviewMobileHost.deviceID
        }
        guard !targets.isEmpty else { return }
        let supportedKinds = runtime.supportedRouteKinds
        await withTaskGroup(of: MacWorkspaceListRefreshOutcome?.self) { group in
            for mac in targets {
                group.addTask { [weak self] in
                    await self?.fetchWorkspaceList(for: mac, supportedKinds: supportedKinds)
                }
            }
            for await outcome in group {
                guard let outcome else { continue }
                // Re-guard after the awaited fetch: a sign-out / user switch /
                // forget may have run, so never write a partition for a Mac that
                // is no longer the signed-in user's, or after sign-out.
                guard isSignedIn,
                      identityProvider?.currentUserID == stackUserID,
                      pairedMacs.contains(where: { $0.macDeviceID == outcome.macDeviceID }),
                      outcome.macDeviceID != activeMacDeviceID else { continue }
                switch outcome.result {
                case let .workspaces(workspaces):
                    setWorkspaces(workspaces, forMac: outcome.macDeviceID, displayName: outcome.displayName)
                    macStatusByMac[outcome.macDeviceID] = .connected
                case .unavailable:
                    // Keep the last-known partition; just gray the section.
                    if !macOrder.contains(outcome.macDeviceID) {
                        macOrder.append(outcome.macDeviceID)
                    }
                    macDisplayNameByMac[outcome.macDeviceID] = outcome.displayName
                    macStatusByMac[outcome.macDeviceID] = .unavailable
                }
            }
        }
    }

    /// One-shot transient `workspace.list` against a single paired Mac, with no
    /// render-grid subscription. Returns the mapped workspaces on success or an
    /// `.unavailable` marker on any failure; always disconnects the transient
    /// client before returning.
    private func fetchWorkspaceList(
        for mac: MobilePairedMac,
        supportedKinds: [CmxAttachTransportKind]
    ) async -> MacWorkspaceListRefreshOutcome? {
        guard let runtime else { return nil }
        let displayName = mac.displayName ?? mac.macDeviceID
        guard let (host, port) = Self.firstReconnectHostPortRoute(mac.routes, supportedKinds: supportedKinds),
              let normalizedHost = MobileShellRouteAuthPolicy.normalizedManualHost(host),
              let route = try? Self.manualHostRoute(host: normalizedHost, port: port),
              MobileShellRouteAuthPolicy.routeAllowsStackAuth(route) else {
            return MacWorkspaceListRefreshOutcome(
                macDeviceID: mac.macDeviceID,
                displayName: displayName,
                result: .unavailable
            )
        }
        let ticket: CmxAttachTicket
        do {
            // Use the same fallback-aware mint `connectManualHost` uses: a legacy
            // Mac that returns `method_not_found` for `mobile.attach_ticket.create`
            // falls back to a synthetic manual ticket that still authorizes the
            // authenticated `workspace.list` below. Calling the raw
            // `requestManualAttachTicket` here would mark every such legacy Mac
            // `.unavailable` and never surface its workspaces.
            ticket = try await manualHostTicket(name: displayName, host: normalizedHost, port: port)
        } catch {
            mobileShellLog.info("secondary mac ticket mint failed mac=\(mac.macDeviceID, privacy: .public): \(String(describing: error), privacy: .private)")
            return MacWorkspaceListRefreshOutcome(
                macDeviceID: mac.macDeviceID,
                displayName: displayName,
                result: .unavailable
            )
        }
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        defer { Task { await client.disconnect() } }
        do {
            let resultData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(method: "workspace.list", params: [:]),
                timeoutNanoseconds: runtime.pairingRequestTimeoutNanoseconds
            )
            let response = try MobileSyncWorkspaceListResponse.decode(resultData)
            let workspaces = response.workspaces.map { remote in
                MobileWorkspacePreview(
                    remote: remote,
                    sourceMacDeviceID: mac.macDeviceID,
                    sourceMacDisplayName: displayName
                )
            }
            return MacWorkspaceListRefreshOutcome(
                macDeviceID: mac.macDeviceID,
                displayName: displayName,
                result: .workspaces(workspaces)
            )
        } catch {
            mobileShellLog.info("secondary mac workspace.list failed mac=\(mac.macDeviceID, privacy: .public): \(String(describing: error), privacy: .private)")
            return MacWorkspaceListRefreshOutcome(
                macDeviceID: mac.macDeviceID,
                displayName: displayName,
                result: .unavailable
            )
        }
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
        // `isSwitchingHeavySession` is owned by `drainPendingHeavySessionTargets`
        // (the only caller that should manage concurrent retargets); a direct
        // call here is sequential by the actor and does not need to set it.
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
        // Carry the real stored id so a legacy synthetic-ticket fallback still keys
        // the live partition by macDeviceID (matching pairedMacs / refresh / forget).
        pendingKnownActiveMacDeviceID = macDeviceID
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
        // After a failed switch to an offline Mac the selection may still point at
        // the unreachable target while the heavy session is back on a different
        // (active) Mac. Re-anchor selection onto the active Mac so the detail view
        // never sits on a silently dead surface (input/replay route to the active
        // Mac's partition, which no longer contains the stale selection).
        reanchorSelectionToActiveMacIfStranded()
        // Re-drive replay for surfaces that registered during the retarget window.
        // In compact mode the detail (and its terminal surface) can mount and
        // request replay while the live client was still the OLD Mac, so that
        // replay resolved against the old partition and was skipped for the new
        // Mac's surface. After the switch connects, re-request replay for every
        // registered surface against the now-active client so the terminal is not
        // left blank until later output/input. No-op when not connected.
        if connectionState == .connected {
            resyncTerminalOutput(reason: "retarget", restartEventStream: true)
        }
        await loadPairedMacs()
    }

    /// If the current selection points at a Mac other than the active one and the
    /// selected workspace is no longer routable (its Mac is not the active Mac),
    /// move the selection onto the active Mac's selected/first workspace.
    ///
    /// Guards against the failed-switch-to-offline-Mac case where selection is
    /// left on the unreachable target while the heavy session reconnected to a
    /// different Mac, which would otherwise present a dead terminal.
    private func reanchorSelectionToActiveMacIfStranded() {
        // A newer target is queued: let the drain switch to it rather than
        // yanking selection back to the just-completed Mac (which would make a
        // slow earlier switch win over the user's latest tap).
        guard pendingHeavySessionTarget == nil else { return }
        guard let activeMacDeviceID else { return }
        guard selectedMacDeviceID != activeMacDeviceID else { return }
        let activePartition = workspacesByMac[activeMacDeviceID] ?? []
        guard !activePartition.isEmpty else { return }
        selectedMacDeviceID = activeMacDeviceID
        // Assigning selectedWorkspaceID re-runs reconcile, but it now resolves to
        // the active Mac (the id is in the active partition), so it is a no-op
        // retarget rather than a loop.
        selectedWorkspaceID = activePartition.first?.id
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
        // Drop the forgotten Mac's partition so it disappears from the aggregated
        // list and stops keeping `hasNoPairedMacs` false.
        forgetMacPartition(macDeviceID)
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
        let attemptID = beginPairingAttempt()
        let ticket: CmxAttachTicket
        do {
            ticket = try CmxAttachTicketInput.decode(rawURL)
        } catch {
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            connectionError = L10n.string("mobile.pairing.invalidCode", defaultValue: "Invalid pairing code.")
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
            return .failed
        }

        do {
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            try await connect(ticket: ticket)
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            return connectionState == .connected && activeTicket != nil ? .connected : .failed
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
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return .failed }
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
        // Resolve the persisted stored id to remove BEFORE disconnecting. When the
        // active Mac is offline the all-devices gate still shows this surface, but
        // `activeTicket` is already nil, so relying on the ticket alone would skip
        // the store removal and the Mac would reappear on the next launch.
        //
        // Prefer a REAL stored id over a synthetic `manual-...` one: a legacy host
        // reconnected via the synthetic-ticket fallback has a `manual-<host>:<port>`
        // ticket id while the stored paired row (and the active partition key) hold
        // the real `macDeviceID`. Removing the synthetic id would leave the real row
        // in storage, so it would reappear on the next launch. Order: the active
        // paired row's id, else a non-`manual-` active partition key, else a
        // non-`manual-` ticket id (covers the rare case with no active row).
        let staleMacID = activeTicket?.macDeviceID
        let nonManual: (String?) -> String? = { id in
            guard let id, !id.isEmpty, !id.hasPrefix("manual-") else { return nil }
            return id
        }
        let persistedMacIDToRemove: String? = pairedMacs.first(where: { $0.isActive })?.macDeviceID
            ?? nonManual(activeMacDeviceID)
            ?? nonManual(staleMacID)
        // Capture the active partition key before disconnect clears the active
        // pointer; it may be a `manual-...` key that differs from the ticket's
        // macDeviceID, so drop the partition by the key the aggregated list uses.
        let staleActivePartitionKey = activeMacDeviceID
        disconnectLiveConnection()
        // Drop the forgotten Mac's partition so Rescan QR returns the user to the
        // pairing flow instead of leaving its stale workspaces in the list.
        if let staleActivePartitionKey {
            forgetMacPartition(staleActivePartitionKey)
        }
        // When the active Mac was ALREADY offline, `clearRemoteConnectionContext`
        // had nulled `activeMacDeviceID` but intentionally kept its (grayed)
        // partition, so `staleActivePartitionKey` is nil and the loop above never
        // drops it. Also drop the resolved persisted id's partition so the offline
        // active Mac's cached workspaces don't survive Rescan and keep
        // `hasNoPairedMacs` false. No-op when it equals the key already dropped.
        if let persistedMacIDToRemove, persistedMacIDToRemove != staleActivePartitionKey {
            forgetMacPartition(persistedMacIDToRemove)
        }
        // Drop the forgotten Mac from the in-memory pairedMacs immediately. The
        // store removal below is fire-and-forget (no reload), and `hasNoPairedMacs`
        // checks `pairedMacs.isEmpty`, so without this Rescan QR would leave the
        // last paired Mac in memory and the gate would never fall to the pairing
        // flow. Remove the active row (this forgets the active Mac) and any row
        // whose id matches the resolved persisted id, for robustness when the
        // active row is not flagged isActive (e.g. an offline active Mac).
        pairedMacs.removeAll { $0.isActive || $0.macDeviceID == persistedMacIDToRemove }
        // Forgetting the active Mac clears the restoring hint so the next launch
        // (and the current disconnected view) shows add-device immediately. Bump
        // the reconnect generation first so an in-flight reconnect can't re-set the
        // hint or the gate flags after the user forgot the Mac.
        storedMacReconnectGeneration &+= 1
        hasKnownPairedMac = false
        isReconnectingStoredMac = false
        didFinishStoredMacReconnectAttempt = false
        if let pairedMacStore, let macID = persistedMacIDToRemove {
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
        // This is a one-shot probe client for the ticket mint; tear down its
        // transport/read loop before returning or throwing. The all-devices
        // refresh mints a ticket per non-active Mac on every sign-in/foreground/
        // pull, so a leaked probe client per Mac per refresh would accumulate
        // persistent transports. (The workspace.list client below is likewise
        // explicitly disconnected.)
        defer { Task { await client.disconnect() } }
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
        // Synthetic create only for the preview host (no real session). A real
        // session that is merely disconnected (remoteClient nil, activeMac dropped
        // or a real Mac) must NOT mint a fake preview workspace into the user's
        // real device list; the all-devices gate can show this surface while
        // disconnected, so creation is a no-op until a reachable Mac is active.
        guard isPreviewHostActive else { return }
        let macID = PreviewMobileHost.deviceID
        let displayName = macDisplayNameByMac[macID] ?? PreviewMobileHost.hostName
        var partition = workspacesByMac[macID] ?? []
        let nextIndex = partition.count + 1
        let workspace = MobileWorkspacePreview(
            id: .init(rawValue: "workspace-\(nextIndex)"),
            name: L10n.workspaceName(index: nextIndex),
            terminals: [
                MobileTerminalPreview(
                    id: .init(rawValue: "workspace-\(nextIndex)-terminal-1"),
                    name: L10n.terminalName(index: 1)
                ),
            ],
            sourceMacDeviceID: macID,
            sourceMacDisplayName: displayName
        )
        partition.append(workspace)
        setWorkspaces(partition, forMac: macID, displayName: displayName)
        selectedMacDeviceID = macID
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
        // Synthetic create only for the preview host (see createWorkspace): a real
        // disconnected session must not fabricate terminals into a real list.
        guard isPreviewHostActive else { return }
        let macID = PreviewMobileHost.deviceID
        let displayName = macDisplayNameByMac[macID] ?? PreviewMobileHost.hostName
        var partition = workspacesByMac[macID] ?? []
        guard let workspaceIndex = partition.firstIndex(where: { $0.id == targetWorkspaceID }) else {
            return
        }
        selectedMacDeviceID = macID
        selectedWorkspaceID = targetWorkspaceID
        let terminalIndex = partition[workspaceIndex].terminals.count + 1
        let terminal = MobileTerminalPreview(
            id: .init(rawValue: "\(partition[workspaceIndex].id.rawValue)-terminal-\(terminalIndex)"),
            name: L10n.terminalName(index: terminalIndex)
        )
        partition[workspaceIndex].terminals.append(terminal)
        setWorkspaces(partition, forMac: macID, displayName: displayName)
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
        setSelectedWorkspaceID(id)
    }

    /// Select a workspace by its `(macDeviceID, workspaceID)` pair.
    ///
    /// The aggregated list groups by Mac and workspace ids are only unique within
    /// a Mac, so a row tap carries its section's device id to disambiguate a
    /// same-id collision across Macs. Pinning the Mac first makes the
    /// ``selectedWorkspaceID`` `didSet` reconcile to the intended partition and
    /// retarget the heavy session to that Mac when needed.
    /// - Parameters:
    ///   - workspaceID: The tapped workspace's identifier.
    ///   - macDeviceID: The source Mac of the section the workspace was tapped in.
    public func selectWorkspace(
        _ workspaceID: MobileWorkspacePreview.ID,
        onMac macDeviceID: String
    ) {
        // Pin the owning Mac before the id so reconcile resolves to this Mac's
        // partition even when another Mac exposes the same workspace id.
        if (workspacesByMac[macDeviceID] ?? []).contains(where: { $0.id == workspaceID }) {
            selectedMacDeviceID = macDeviceID
        }
        selectedWorkspaceID = workspaceID
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
        await sendRemoteTerminalInput(text + "\r")
    }

    public func sendTerminalRawInput(_ text: String) {
        #if DEBUG
        mobileShellLog.debug("enqueue raw terminal input byteCount=\(text.utf8.count, privacy: .public)")
        #endif
        // Route by the active Mac's selection only, so a composer keystroke during
        // a heavy-session retarget never enqueues another Mac's ids.
        guard let target = activeSelectedSendTarget else {
            #if DEBUG
            mobileShellLog.info("skip raw terminal input enqueue selectedWorkspace=\(self.selectedWorkspace == nil ? 0 : 1, privacy: .public) selectedTerminal=\(self.selectedTerminalID == nil ? 0 : 1, privacy: .public)")
            #endif
            return
        }
        let workspaceID = target.workspaceID
        let terminalID = target.terminalID
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
        guard let target = activeSelectedSendTarget else { return }
        await submitTerminalRawInput(text, workspaceID: target.workspaceID, terminalID: target.terminalID)
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
        // Route only into the active Mac's partition: a surface that is not on
        // the active Mac resolves to nil and the input is dropped rather than
        // sent to the wrong Mac's client.
        guard let workspaceID = workspaceID(forTerminalID: surfaceID) else { return }
        let terminalID = MobileTerminalPreview.ID(rawValue: surfaceID)
        await submitTerminalRawInput(text, workspaceID: workspaceID, terminalID: terminalID)
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
                    setActiveMac(from: ticket)
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

    /// Tear down the live heavy session (active client, terminal-output
    /// tracking, render-grid listener + watchdog) while **keeping every Mac's
    /// list partition intact**.
    ///
    /// This is the heavy-session-vs-list split: the active Mac's last-known
    /// workspaces stay in the aggregated list, grayed `.unavailable`, instead of
    /// vanishing. Other Macs' partitions are untouched. Used by every
    /// connect-failure / disconnect / retarget path; only ``signOut`` drops the
    /// partitions wholesale.
    private func clearRemoteConnectionContext() {
        connectionGeneration = UUID()
        cancelRemoteOperationTasks()
        clearActiveConnectionContext()
        // Gray the active Mac's section before dropping the active-Mac pointer,
        // so its last-known partition is shown as unavailable, not removed.
        if let activeMacDeviceID {
            macStatusByMac[activeMacDeviceID] = .unavailable
        }
        macConnectionStatus = .unavailable
        activeMacDeviceID = nil
        // A failed/torn-down connect never reached setActiveMac, so drop the
        // pending known-mac id rather than letting it leak into a later connect.
        pendingKnownActiveMacDeviceID = nil
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

    private func beginPairingAttempt() -> UUID {
        let attemptID = UUID()
        pairingAttemptID = attemptID
        connectionGeneration = UUID()
        cancelRemoteOperationTasks()
        rawTerminalInputBuffer.clear()
        connectionError = nil
        return attemptID
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
        // workspace.create runs over the active Mac's `remoteClient`. Block only a
        // genuine cross-Mac retarget window: selection pinned to a DIFFERENT Mac
        // than the active one (tap on Mac B while the client is still A's). A nil
        // selection is allowed, so the first workspace can be created on a
        // connected-but-empty Mac (empty list -> nil selection -> nil selectedMac).
        if let selectedMacDeviceID, selectedMacDeviceID != activeMacDeviceID { return }
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
              let activeMacDeviceID,
              let requestedID = explicitWorkspaceID ?? selectedWorkspace?.id else { return }
        // terminal.create runs over the active Mac's `remoteClient`. Block a
        // genuine cross-Mac retarget window: selection pinned to a DIFFERENT Mac
        // than the active one (viewing Mac B's workspace while the client is still
        // A's), so under a workspace-id collision the create can't land on Mac A.
        // A nil selection is allowed (the explicit-id partition check below is the
        // real routing gate).
        if let selectedMacDeviceID, selectedMacDeviceID != activeMacDeviceID { return }
        // The requested workspace must actually be in the active Mac's partition (a
        // row "+" can pass an explicit id that is not on the active Mac); this is
        // the authoritative routing check that keeps the create on the right Mac.
        guard (workspacesByMac[activeMacDeviceID] ?? []).contains(where: { $0.id == requestedID }) else { return }
        let workspaceID = requestedID.rawValue
        let requestedWorkspaceID = requestedID
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
        guard let target = activeSelectedSendTarget else {
            #if DEBUG
            mobileShellLog.info("skip remote terminal input selectedWorkspace=\(self.selectedWorkspace == nil ? 0 : 1, privacy: .public) selectedTerminal=\(self.selectedTerminalID == nil ? 0 : 1, privacy: .public)")
            #endif
            return
        }
        await sendRemoteTerminalInput(text, workspaceID: target.workspaceID, terminalID: target.terminalID)
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
        // Paste routes by the active Mac's selection only, so a pasted image
        // during a retarget never lands on a different Mac's client.
        guard let target = activeSelectedSendTarget else { return }
        guard remoteClient != nil else { return }
        await sendRemoteTerminalPasteImage(
            data,
            format: format,
            workspaceID: target.workspaceID,
            terminalID: target.terminalID
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

    /// Resolve a surface id to its workspace **only within the active Mac's
    /// partition**, the routing safety chokepoint.
    ///
    /// Every heavy-session send path (input, paste, scroll, click, viewport,
    /// replay) resolves its surface through this and bails on `nil`. Because the
    /// live `remoteClient` is always the active Mac's client and this scans only
    /// the active Mac's partition, a foreign or stale surface (e.g. another Mac's
    /// surface still mounted during a retarget, or a same-id collision) resolves
    /// to `nil` and the send becomes a safe no-op instead of dispatching a
    /// foreign `workspace_id` to the wrong Mac's client. Surface ids are only
    /// unique within a Mac, so an unscoped scan could otherwise mis-route.
    private func workspaceID(forTerminalID terminalID: String) -> MobileWorkspacePreview.ID? {
        guard let activeMacDeviceID else { return nil }
        // Mid-retarget the mounted surface belongs to the just-selected (not-yet-
        // active) Mac, while `remoteClient` is still the old active Mac's. Drop the
        // send in that window (the same tradeoff `activeSelectedSendTarget` makes
        // for the selection-keyed paths); after the switch settles selection equals
        // the active Mac and the post-switch resync re-drives replay. Outside a
        // retarget reconcile/reanchor keep these equal, so this is a no-op guard.
        // Belt-and-suspenders for an across-Mac terminal-id collision, which is
        // effectively unreachable because Mac surface ids are UUIDs.
        if let selectedMacDeviceID, selectedMacDeviceID != activeMacDeviceID { return nil }
        for workspace in workspacesByMac[activeMacDeviceID] ?? [] {
            if workspace.terminals.contains(where: { $0.id.rawValue == terminalID }) {
                return workspace.id
            }
        }
        return nil
    }

    /// Whether `workspaceID` is in the active Mac's partition.
    ///
    /// The routing chokepoint for workspace-scoped actions (rename, pin) that send
    /// over the active Mac's `remoteClient`: a workspace not on the active Mac (a
    /// non-active section, or a cross-Mac id collision) returns `false`, so the
    /// action is a safe no-op instead of mutating the wrong Mac's workspace.
    private func workspaceIsOnActiveMac(_ workspaceID: MobileWorkspacePreview.ID) -> Bool {
        guard let activeMacDeviceID else { return false }
        return (workspacesByMac[activeMacDeviceID] ?? []).contains { $0.id == workspaceID }
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

    // MARK: - Workspace partitions (per source Mac)

    /// Group a flat workspace list into per-Mac partitions plus a stable device
    /// order and display-name map.
    ///
    /// Used to seed the store from preview/test fixtures. Workspaces with the
    /// same ``MobileWorkspacePreview/sourceMacDeviceID`` land in one partition;
    /// device order follows first appearance so the derived ``workspaces`` keeps
    /// a stable, non-reshuffling order.
    private static func partitions(
        from workspaces: [MobileWorkspacePreview]
    ) -> (
        workspacesByMac: [String: [MobileWorkspacePreview]],
        macOrder: [String],
        displayNames: [String: String]
    ) {
        var byMac: [String: [MobileWorkspacePreview]] = [:]
        var order: [String] = []
        var names: [String: String] = [:]
        for workspace in workspaces {
            let macID = workspace.sourceMacDeviceID
            if byMac[macID] == nil {
                order.append(macID)
            }
            byMac[macID, default: []].append(workspace)
            if names[macID] == nil, !workspace.sourceMacDisplayName.isEmpty {
                names[macID] = workspace.sourceMacDisplayName
            }
        }
        return (byMac, order, names)
    }

    /// Replace a single Mac's partition, registering it in ``macOrder`` and
    /// ``macDisplayNameByMac`` if newly seen. This is the only sanctioned write
    /// onto the aggregated list: scoping every workspace-list result to its
    /// producing Mac is what stops one Mac's refresh from clobbering another's
    /// partition (the #1 correctness risk of the aggregated model).
    private func setWorkspaces(
        _ macWorkspaces: [MobileWorkspacePreview],
        forMac macDeviceID: String,
        displayName: String?
    ) {
        if workspacesByMac[macDeviceID] == nil, !macOrder.contains(macDeviceID) {
            macOrder.append(macDeviceID)
        }
        workspacesByMac[macDeviceID] = macWorkspaces
        if let displayName, !displayName.isEmpty {
            macDisplayNameByMac[macDeviceID] = displayName
        } else if macDisplayNameByMac[macDeviceID] == nil,
                  let firstName = macWorkspaces.first?.sourceMacDisplayName,
                  !firstName.isEmpty {
            macDisplayNameByMac[macDeviceID] = firstName
        }
    }

    /// The display name for a Mac in the grouped list, falling back to the
    /// device id when no name was advertised.
    public func macDisplayName(forMacDeviceID macDeviceID: String) -> String {
        macDisplayNameByMac[macDeviceID] ?? macDeviceID
    }

    /// The list-section connectivity status for a Mac.
    ///
    /// The active Mac mirrors ``macConnectionStatus``; others reflect their last
    /// `workspace.list` refresh (`.connected` on success, `.unavailable` when
    /// unreachable). Defaults to `.unavailable` for a Mac not yet refreshed.
    public func macStatus(forMacDeviceID macDeviceID: String) -> MobileMacConnectionStatus {
        macStatusByMac[macDeviceID] ?? .unavailable
    }

    /// Whether the first ``loadPairedMacs`` after sign-in has resolved.
    ///
    /// Gates ``hasNoPairedMacs`` so an already-paired user's cold launch (Stack
    /// restored, but the paired-Mac load and reconnect still in flight) does not
    /// momentarily report "no Macs" and flash the pairing screen before the
    /// aggregated list appears. Reset on sign-out.
    public private(set) var hasCompletedInitialPairedMacLoad: Bool = false

    /// Whether this device has zero paired Macs, gating the root view between the
    /// aggregated list and the pairing/empty surface.
    ///
    /// Reports `false` until ``hasCompletedInitialPairedMacLoad`` is set, so a
    /// restored-but-not-yet-loaded session shows the list path (which renders a
    /// neutral loading surface) instead of flashing pairing. After the initial
    /// load it is `true` only when no **real** partition holds workspaces, no Mac
    /// is in the switcher, and no heavy session is live.
    ///
    /// The synthetic preview-Mac partition is excluded from the partition check in
    /// a production session (`runtime != nil`): ``signOut`` reseeds that partition,
    /// so counting it would keep this `false` after a real re-sign-in with no
    /// paired Macs and trap the user out of pairing. In a runtime-less SwiftUI
    /// preview the preview partition is the only content, so it keeps this `false`
    /// and previews still show the list.
    public var hasNoPairedMacs: Bool {
        guard hasCompletedInitialPairedMacLoad else { return false }
        let hasRealPartition: Bool
        if runtime == nil {
            hasRealPartition = !workspacesByMac.isEmpty
        } else {
            // Ignore the synthetic preview partition in a production session.
            hasRealPartition = workspacesByMac.keys.contains { $0 != PreviewMobileHost.deviceID }
        }
        return !hasRealPartition && pairedMacs.isEmpty && activeMacDeviceID == nil
    }

    /// Apply a workspace-list response for the **active** Mac's partition only.
    ///
    /// Every wholesale list write funnels here and is scoped to
    /// ``activeMacDeviceID`` so it can never overwrite another Mac's partition.
    /// `mergeExistingWorkspaces` merges into the active Mac's existing partition
    /// (used by create paths that return a partial list).
    private func applyRemoteWorkspaceList(
        _ response: MobileSyncWorkspaceListResponse,
        preferActiveTicketTarget: Bool = false,
        mergeExistingWorkspaces: Bool = false
    ) {
        guard let activeMacDeviceID else { return }
        let displayName = macDisplayNameByMac[activeMacDeviceID] ?? connectedHostName
        let remoteWorkspaces = remoteWorkspacesPreservingSnapshots(
            from: response,
            forMac: activeMacDeviceID,
            displayName: displayName
        )
        if mergeExistingWorkspaces {
            var mergedWorkspaces = workspacesByMac[activeMacDeviceID] ?? []
            for remoteWorkspace in remoteWorkspaces {
                if let existingIndex = mergedWorkspaces.firstIndex(where: { $0.id == remoteWorkspace.id }) {
                    mergedWorkspaces[existingIndex] = remoteWorkspace
                } else {
                    mergedWorkspaces.append(remoteWorkspace)
                }
            }
            setWorkspaces(mergedWorkspaces, forMac: activeMacDeviceID, displayName: displayName)
        } else {
            setWorkspaces(remoteWorkspaces, forMac: activeMacDeviceID, displayName: displayName)
        }
        if preferActiveTicketTarget, selectActiveTicketTargetIfAvailable() {
            return
        }
        // A selection still present in the active Mac's refreshed partition is
        // kept; otherwise re-anchor to the Mac's selected/first workspace.
        if let selectedWorkspaceID,
           selectedMacDeviceID == activeMacDeviceID,
           (workspacesByMac[activeMacDeviceID] ?? []).contains(where: { $0.id == selectedWorkspaceID }) {
            syncSelectedTerminalForWorkspace()
            return
        }
        // Only re-anchor selection to the active Mac when nothing valid is
        // selected, so refreshing the active Mac never yanks the user off a
        // workspace they have selected on a different Mac.
        let selectionIsValid = selectedMacDeviceID
            .flatMap { workspacesByMac[$0] }?
            .contains(where: { $0.id == selectedWorkspaceID }) ?? false
        if selectionIsValid { return }
        selectedMacDeviceID = activeMacDeviceID
        setSelectedWorkspaceID(
            response.workspaces.first(where: \.isSelected)
                .map { MobileWorkspacePreview.ID(rawValue: $0.id) }
                ?? workspacesByMac[activeMacDeviceID]?.first?.id
        )
        syncSelectedTerminalForWorkspace()
    }

    /// Map a workspace-list response into previews tagged with `macDeviceID`,
    /// preserving per-terminal viewport-fit snapshots from that Mac's existing
    /// partition so a list refresh does not reset live render state.
    private func remoteWorkspacesPreservingSnapshots(
        from response: MobileSyncWorkspaceListResponse,
        forMac macDeviceID: String,
        displayName: String
    ) -> [MobileWorkspacePreview] {
        let existing = workspacesByMac[macDeviceID] ?? []
        return response.workspaces.map { remoteWorkspace in
            var workspace = MobileWorkspacePreview(
                remote: remoteWorkspace,
                sourceMacDeviceID: macDeviceID,
                sourceMacDisplayName: displayName
            )
            guard let existingWorkspace = existing.first(where: { $0.id == workspace.id }) else {
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

    /// Keep ``selectedMacDeviceID`` consistent with ``selectedWorkspaceID`` and
    /// retarget the heavy session when the selected Mac changes.
    ///
    /// Resolves which Mac owns the selected workspace. When that differs from the
    /// previously selected Mac, the heavy render-grid session must move to the
    /// new Mac, so the live connection is reconnected to it (Phase 1: the active
    /// Mac is reconnected on demand; live secondary subscriptions are Phase 2).
    private func reconcileSelectedMacForSelectedWorkspace(previousMacDeviceID: String?) {
        guard let selectedWorkspaceID else {
            selectedMacDeviceID = nil
            return
        }
        // Prefer the previously selected Mac if it still owns the id (avoids
        // hopping Macs on a same-id collision), else find the owning partition.
        let resolvedMac: String?
        if let previousMacDeviceID,
           (workspacesByMac[previousMacDeviceID] ?? []).contains(where: { $0.id == selectedWorkspaceID }) {
            resolvedMac = previousMacDeviceID
        } else {
            resolvedMac = macOrder.first { macID in
                (workspacesByMac[macID] ?? []).contains(where: { $0.id == selectedWorkspaceID })
            }
        }
        guard let resolvedMac else { return }
        selectedMacDeviceID = resolvedMac
        retargetHeavySessionIfNeeded(toMacDeviceID: resolvedMac)
    }

    /// Move the live heavy session to `macDeviceID` when the selection lands on a
    /// Mac other than the currently active one.
    ///
    /// Phase 1 keeps exactly one render-grid stream. Switching the selected Mac
    /// reconnects the single live client to the new Mac (reusing the paired-Mac
    /// reconnect path), which tears down the old Mac's stream without touching
    /// any other Mac's list partition. A no-op when the selection is on the
    /// active Mac, when there is no `runtime` (preview), or when no
    /// `pairedMacStore` is available to reconnect through.
    private func retargetHeavySessionIfNeeded(toMacDeviceID macDeviceID: String) {
        guard runtime != nil, pairedMacStore != nil else { return }
        guard macDeviceID != activeMacDeviceID else { return }
        guard macDeviceID != PreviewMobileHost.deviceID else { return }
        // Record the latest requested target. A switch already in flight will
        // drain this on completion, so the user's most recent tap wins instead of
        // being dropped (tap Mac B, then Mac C before B connects -> end on C).
        pendingHeavySessionTarget = macDeviceID
        guard !isSwitchingHeavySession else { return }
        isSwitchingHeavySession = true
        Task { @MainActor [weak self] in
            await self?.drainPendingHeavySessionTargets()
        }
    }

    /// Switch to the latest requested Mac, then keep switching while newer targets
    /// arrive, so concurrent selections collapse to the last one. Owns the
    /// ``isSwitchingHeavySession`` flag for the whole drain (``switchToMac`` no
    /// longer manages it) so a later tap during a switch supersedes the earlier
    /// one rather than racing a per-call `defer`.
    private func drainPendingHeavySessionTargets() async {
        defer { isSwitchingHeavySession = false }
        while let target = pendingHeavySessionTarget {
            pendingHeavySessionTarget = nil
            // Skip if the selection moved back to the now-active Mac while we
            // looped, or the target vanished (e.g. forgotten) meanwhile.
            guard target != activeMacDeviceID,
                  pairedMacs.contains(where: { $0.macDeviceID == target }) else { continue }
            await switchToMac(macDeviceID: target)
        }
    }

    /// True while a heavy-session retarget drain is in flight, so a
    /// selection-driven reconcile records a pending target instead of stacking a
    /// second concurrent switch.
    private var isSwitchingHeavySession = false

    /// The most recently requested heavy-session target Mac, set by a selection
    /// reconcile and drained by ``drainPendingHeavySessionTargets``. The latest
    /// write wins, so the user's last device tap is the one that connects.
    private var pendingHeavySessionTarget: String?

    private func selectActiveTicketTargetIfAvailable() -> Bool {
        guard let activeTicket else {
            return false
        }
        // The attach ticket's target lives on the active Mac, so scope the lookup
        // and selection to that Mac's partition.
        let ticketWorkspaceID = MobileWorkspacePreview.ID(rawValue: activeTicket.workspaceID)
        let partition = activeMacDeviceID.flatMap { workspacesByMac[$0] } ?? workspaces
        guard let workspace = partition.first(where: { $0.id == ticketWorkspaceID }) else {
            return false
        }
        selectedMacDeviceID = activeMacDeviceID
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

    /// The stable partition key for an attach ticket's Mac.
    ///
    /// Real pairings carry a device id; manual/synthetic tickets carry a
    /// `manual-...` placeholder. Either way it is non-empty and unique enough to
    /// partition the aggregated list, so it doubles as the partition key.
    private static func macPartitionKey(for ticket: CmxAttachTicket) -> String {
        ticket.macDeviceID.isEmpty ? "manual-\(ticket.workspaceID)" : ticket.macDeviceID
    }

    /// Resolve the active partition key, preferring a known stored Mac id over the
    /// ticket-derived one.
    ///
    /// A stored Mac always has a stable real `macDeviceID` from pairing, but on
    /// reconnect a legacy host that lacks `mobile.attach_ticket.create` falls back
    /// to a synthetic `manual-<host>:<port>` ticket. Keying the active partition by
    /// the synthetic ticket id then diverges from the `pairedMacs` row (the
    /// secondary refresh, switch, and forget all use the real id), duplicating the
    /// Mac across two sections. Threading the known stored id keeps the live
    /// partition under the same key everything else uses. First-time pairing /
    /// manual-host / preview pass `nil` and fall back to the ticket-derived key.
    /// - Parameters:
    ///   - knownMacDeviceID: The real stored `macDeviceID` of the reconnecting /
    ///     switching paired Mac, or `nil` for a first-time / manual / preview
    ///     connection.
    ///   - ticket: The attach ticket the connection was established with.
    /// - Returns: The partition key to use for the active Mac.
    static func activePartitionKey(
        knownMacDeviceID: String?,
        ticket: CmxAttachTicket
    ) -> String {
        if let knownMacDeviceID, !knownMacDeviceID.isEmpty, !knownMacDeviceID.hasPrefix("manual-") {
            return knownMacDeviceID
        }
        return macPartitionKey(for: ticket)
    }

    /// Promote `ticket`'s Mac to the active (heavy-session) Mac and record its
    /// display name, so subsequent ``applyRemoteWorkspaceList`` calls write that
    /// Mac's partition and selection tags resolve to it.
    ///
    /// - Parameters:
    ///   - ticket: The attach ticket the connection was established with.
    ///   - knownMacDeviceID: The real stored `macDeviceID` when reconnecting or
    ///     switching a known paired Mac, so a legacy synthetic-ticket fallback
    ///     does not partition the live session under a `manual-...` id that
    ///     diverges from the `pairedMacs` row. `nil` for first-time/manual/preview.
    private func setActiveMac(from ticket: CmxAttachTicket, knownMacDeviceID: String? = nil) {
        // Prefer an explicit argument, else the transient set by the stored-Mac
        // reconnect/switch paths; clear the transient so it never leaks into a
        // later first-time/manual connect.
        let resolvedKnownID = knownMacDeviceID ?? pendingKnownActiveMacDeviceID
        pendingKnownActiveMacDeviceID = nil
        let macID = Self.activePartitionKey(knownMacDeviceID: resolvedKnownID, ticket: ticket)
        let displayName = ticket.macDisplayName ?? ticket.macDeviceID
        // Drop the synthetic preview-host partition the moment a real Mac becomes
        // active: the seeded preview workspaces are not a real device and must not
        // linger in the aggregated list alongside live Macs.
        if macID != PreviewMobileHost.deviceID {
            removeMacPartition(PreviewMobileHost.deviceID)
            if selectedMacDeviceID == PreviewMobileHost.deviceID {
                selectedMacDeviceID = nil
            }
        }
        activeMacDeviceID = macID
        if !macOrder.contains(macID) {
            macOrder.append(macID)
        }
        if !displayName.isEmpty {
            macDisplayNameByMac[macID] = displayName
        }
        macStatusByMac[macID] = macConnectionStatus
    }

    /// Drop a Mac's partition and its order/name/status bookkeeping entirely.
    private func removeMacPartition(_ macDeviceID: String) {
        workspacesByMac.removeValue(forKey: macDeviceID)
        macStatusByMac.removeValue(forKey: macDeviceID)
        macDisplayNameByMac.removeValue(forKey: macDeviceID)
        macOrder.removeAll { $0 == macDeviceID }
    }

    /// Drop a forgotten Mac's partition and re-anchor selection off it.
    ///
    /// Forgetting a Mac must remove its workspaces from the aggregated list, not
    /// just its paired-Mac store row: otherwise ``deviceSections`` keeps showing
    /// the forgotten Mac's last-known workspaces and ``hasNoPairedMacs`` stays
    /// `false` (so the root gate never falls back to pairing). If the forgotten
    /// Mac was the active or selected Mac, the active pointer and selection are
    /// cleared and re-anchored to a remaining partition so the detail view never
    /// sits on a dropped Mac's workspace.
    private func forgetMacPartition(_ macDeviceID: String) {
        let wasActive = activeMacDeviceID == macDeviceID
        let wasSelected = selectedMacDeviceID == macDeviceID
        removeMacPartition(macDeviceID)
        if wasActive {
            activeMacDeviceID = nil
        }
        guard wasSelected || wasActive else { return }
        // Re-anchor onto a remaining Mac's first workspace, or clear selection
        // entirely when nothing is left (the gate then routes to pairing).
        if let nextMac = macOrder.first(where: { !(workspacesByMac[$0]?.isEmpty ?? true) }) {
            selectedMacDeviceID = nextMac
            selectedWorkspaceID = workspacesByMac[nextMac]?.first?.id
        } else {
            selectedMacDeviceID = nil
            selectedWorkspaceID = nil
        }
    }

    private func applyPreviewTicket(_ ticket: CmxAttachTicket, route: CmxAttachRoute) {
        let terminalID = ticket.terminalID ?? "attached-terminal"
        let macID = Self.macPartitionKey(for: ticket)
        let displayName = ticket.macDisplayName ?? ticket.macDeviceID
        activeMacDeviceID = macID
        let previewWorkspaces = [
            MobileWorkspacePreview(
                id: .init(rawValue: ticket.workspaceID),
                name: L10n.string("mobile.preview.attachedWorkspaceName", defaultValue: "Attached Workspace"),
                terminals: [
                    MobileTerminalPreview(
                        id: .init(rawValue: terminalID),
                        name: L10n.string("mobile.preview.attachedTerminalName", defaultValue: "Attached Terminal")
                    ),
                ],
                sourceMacDeviceID: macID,
                sourceMacDisplayName: displayName
            ),
        ]
        setWorkspaces(previewWorkspaces, forMac: macID, displayName: displayName)
        selectedMacDeviceID = macID
        selectedWorkspaceID = previewWorkspaces.first?.id
        selectedTerminalID = previewWorkspaces.first?.terminals.first?.id
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
