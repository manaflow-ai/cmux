#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileArtifacts
import CmuxMobileBrowserStream
import CmuxMobileChief
import CmuxMobileDesign
import CmuxMobileFeed
#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
#endif
import CmuxMobileModel
import CmuxMobileNotifications
import CmuxMobileTransport
import Foundation
import Observation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

private let log = Logger(subsystem: "dev.cmux.mobile", category: "live")

/// Wires the signed-in app to real data, from sign-in on (setup included):
/// registers this phone in the active team (the personal space
/// `personal-<userId>` when the account has no teams), keeps the team's Macs
/// live from presence, finds the account's Macs in every other team and the
/// personal space (`GET /v1/me/macs`) and moves to the one where a Mac is,
/// holds a link to the selected online Mac over the Settings transport, and
/// feeds the daemon's workspaces, acpmux chats, the Feed and Chief from that
/// link.
@MainActor
@Observable
public final class LiveCoordinator {
    public internal(set) var banner: ConnectionBannerState?
    public private(set) var registeredTeamID: String?
    public private(set) var presenceConnected = false
    /// When the presence socket last went down, until its next hello (``presenceReturned``).
    private var presenceLostAt: ContinuousClock.Instant?
    /// When the last network path change redialed the links.
    private var lastPathNudge: ContinuousClock.Instant?
    public internal(set) var chiefStatus: String?
    /// Pairing with the linked Mac (verify/phone-approvals.md): the Mac asks the
    /// user the first time; Allow then signs with the approval key.
    public internal(set) var pairingState: LinkPairing.State = .idle
    /// The last time the phone moved to another team because one of the
    /// account's Macs is there (the shell shows a toast).
    public private(set) var followed: Followed?

    /// A move to the team where the account's Mac is.
    public struct Followed: Equatable, Sendable {
        public let serial: Int
        public let teamID: String
        public let teamName: String
        public let macName: String
    }

    /// Called after a move to another team (persists the Stack selection).
    @ObservationIgnored public var onFollow: ((String) -> Void)?
    /// A Mac left the account (removed here or on another device), after
    /// the store forgot it: screens showing one of its workspaces close.
    @ObservationIgnored public var onMacRemoved: ((String) -> Void)?
    /// A terminal tab drew output on a Mac (tab id, Mac id), or (nil tab) any
    /// of that Mac's may have (`WorkspaceSync.onTerminalOutput`).
    @ObservationIgnored public var onTerminalOutput: (@MainActor (String?, String) -> Void)?

    /// One session per Mac this phone links (`MacLinkPolicy`): each has its
    /// own link, workspace list, chats and Feed items, so two Macs work at
    /// once (PROTOCOL.md "One link per Mac").
    private(set) var sessions: [String: MacSession] = [:]
    /// The focused Mac: the one the person chose last (remembered per team),
    /// else the first online one. Its link drives the banner and Chief.
    public internal(set) var focusedMacID: String?
    /// Stands in for the focused session while there is none (never dials).
    @ObservationIgnored let idleSession: MacSession
    /// Which Macs keep a link (lazy, idle teardown, at most `maxLinks`).
    @ObservationIgnored public var linkPolicy = MacLinkPolicy()
    /// The Macs whose data is on screen (nil: every Mac). Until the shell
    /// says, none: only the focused Mac dials at launch (lazy links).
    @ObservationIgnored var showingMacs: Set<String>? = []
    /// When each Mac was last on screen (or focused).
    @ObservationIgnored var lastShown: [String: ContinuousClock.Instant] = [:]
    /// Terminal tabs of a Mac whose session closed (another team's list loaded, the
    /// policy closed it) while their pages stay on screen: the Mac's next session
    /// takes them back, so they reattach on its link and follow its state instead of
    /// waiting on a session that is gone (one live state per Mac).
    @ObservationIgnored var parkedTerminals: [String: [MacSession.WeakTerminal]] = [:]
    @ObservationIgnored var expiryTask: Task<Void, Never>?
    /// The transport settings every link dials with.
    @ObservationIgnored private var transport: CmuxMobileTransport.TransportKind
    @ObservationIgnored private var relayOnly: Bool
    @ObservationIgnored private var blockUDP: Bool
    @ObservationIgnored private let dialer: any MacLinkDialer
    @ObservationIgnored let feedStore: FeedStore

    /// The focused Mac's session, else the idle stand-in.
    var focused: MacSession { focusedMacID.flatMap { sessions[$0] } ?? idleSession }
    /// The focused Mac's link (status, Settings, the shell's link target).
    public var link: LinkController { focused.link }
    /// The focused Mac's workspace sync.
    public var workspaces: WorkspaceSync { focused.workspaces }
    /// The focused Mac's acpmux client.
    public var acpmux: AcpmuxHub { focused.acpmux }
    /// This phone's APNs registration (the token goes on the link device id).
    public let push = PushRegistration.shared
    /// Whether the service could include a TURN relay in `GET /v1/ice` (nil
    /// before the first look). Without one, WebRTC outside the Mac's network
    /// may fail, and the app says so.
    public internal(set) var relayAvailable: Bool?
    /// The focused Mac's theme and wallpaper for the chrome (ask-87d30da8e5).
    @ObservationIgnored let appearance = MacAppearanceFeed()
    #if canImport(CmuxMobileLinkFFI)
    /// Other devices waiting for a linked Mac's Allow, answered from this phone (ask-45c37458ea).
    public let pairRequests = MacPairRequests()
    /// Each Mac's one-request catch-up cursors (`LiveCoordinator+CatchUp.swift`, off by default).
    @ObservationIgnored let catchUps = MacCatchUps()
    #endif
    /// Every linked Mac's tabs as its `tabs` service pushes them: what the grid's cards show
    /// of tabs this phone never opened. The shell sets its sink (the phone's card store).
    @ObservationIgnored public let tabs = MacTabsFeed()
    /// The focused Mac's Feed source.
    public var feed: LiveFeed { focused.feed }
    /// The focused Mac's terminal agents' events in the Feed.
    public var terminalFeed: TerminalFeed { focused.terminalFeed }

    @ObservationIgnored let store: AppStore
    @ObservationIgnored let api: LiveAPI
    @ObservationIgnored let identity: DeviceIdentity
    #if DEBUG
    /// This phone's device ids for the account (link, then presence): the ids a Mac lists the phone by.
    /// DEBUG only: the dogfood readiness receipt is its one reader.
    public var deviceIDs: [String] { [identity.link, identity.presence] }
    #endif
    /// Where `identity` and the pairing keys are kept (the Keychain; memory in tests).
    @ObservationIgnored let secrets: any DeviceSecretStore
    @ObservationIgnored let userID: String
    @ObservationIgnored let deviceName: String
    /// The phone's keys; nil (tests, mock) skips pairing.
    @ObservationIgnored let pairing: LinkPairing?
    @ObservationIgnored let clock: any Clock<Duration>
    /// `clock`'s now, for the instants kept beside its sleeps (link idle times, link down since).
    @ObservationIgnored let instants: ClockInstants
    @ObservationIgnored private var presence: PresenceListener?
    @ObservationIgnored private var isBackgrounded = false
    /// UIKit's `willEnterForeground` already resumed the links for this return
    /// (`followForegroundNotification`): the scene's `.active` a frame or more later is a repeat.
    @ObservationIgnored private var foregroundedEarly = false
    @ObservationIgnored private var foregroundObserver: NSObjectProtocol?
    /// Pre-wakes the focused Mac's link as the keyboard comes up (``followKeyboard()``).
    @ObservationIgnored private var keyboardObserver: NSObjectProtocol?
    /// The Mac whose link a call (a Chief call, voice mode) uses (`setCallMac`).
    @ObservationIgnored var callMacID: String?
    /// The hold that keeps that link out of the park, and the link it is on.
    @ObservationIgnored var callHold: (link: ObjectIdentifier, hold: LinkAwakeHold)?
    /// When the scene last went to the background (ContinuousClock counts the suspension).
    @ObservationIgnored private var backgroundedAt: ContinuousClock.Instant?
    /// Major connectivity incidents of a cmux team account, for the team's Slack (PROTOCOL.md
    /// "Connectivity incidents"); idle for everyone else.
    @ObservationIgnored let incidents: ConnectivityIncidentReporter
    @ObservationIgnored private var teamTask: Task<Void, Never>?
    /// The banner's slot: quiet link states wait out their bound before they show (`phaseChanged`).
    @ObservationIgnored lazy var bannerHold = HeldNotice<ConnectionBannerState>(clock: clock) { [weak self] in
        self?.banner = $0
    }
    /// Macs a link was connected to (the banner's caller passes it on; a lost link to one
    /// redials on its own).
    @ObservationIgnored var connectedMacIDs: Set<String> = []
    /// The acpmux session (and Mac) each cached chat store was built for (nil: unbound).
    /// `provisional`: built before the Mac's tree listed the tab (a relaunch, a link still
    /// coming up), from the session the phone kept, or loading; rebuilt once the tree comes,
    /// whatever it says.
    @ObservationIgnored var sourcedSessions: [String: (tabID: String, macID: String, session: String?, provisional: Bool)] = [:]
    /// Where agent chats keep their newest records on this phone (each Mac's acpmux sources use it).
    @ObservationIgnored public var transcriptCache: AgentTranscriptCache? = .standard
    /// The session each provisional chat's kept records name, once read from disk
    /// (``PendingAgentSource``): the rebuild opens it even if the cache's memory let the entry go.
    @ObservationIgnored var keptSessionIDs: [String: String] = [:]
    /// The loading chat source of each tab whose Mac has not sent its tree yet: the prompts it
    /// holds go to the tab's real source once that is built (``handOverHeldPrompts(key:to:)``).
    /// Held strongly: the store that owned it is dropped before the new one asks for its source.
    @ObservationIgnored var pendingSources: [String: PendingAgentSource] = [:]
    /// The account was deleted: sign-out keeps nothing of it.
    @ObservationIgnored public internal(set) var accountDeleted = false
    /// Signed out: nothing more is saved for the account.
    @ObservationIgnored var stopped = false
    /// "Remove This iPhone from My Macs" is running.
    @ObservationIgnored var removalRunning = false
    /// How many times this phone was removed from its Macs (tests).
    @ObservationIgnored public internal(set) var removedFromMacsCount = 0
    @ObservationIgnored var chiefLive = false
    /// The Mac whose link Chief runs on.
    @ObservationIgnored var chiefMacID: String?
    /// The link Chief runs (or is starting) on.
    @ObservationIgnored var chiefLink: ObjectIdentifier?
    /// A `startChief` is opening the channel (Try Again does not start a second one).
    @ObservationIgnored var chiefStarting = false
    /// Looks at the account's Macs in every team (`/me/macs`) on `clock`.
    @ObservationIgnored let discovery: MacDiscoveryPoll
    /// Follows the phone's network (Wi-Fi, cellular, airplane mode).
    @ObservationIgnored private var networkTask: Task<Void, Never>?
    /// The account's Macs that were online at the last look (nil before the first).
    @ObservationIgnored private var previouslyOnline: Set<String>?
    /// The account's own Macs at the last discovery (nil before the first):
    /// one that drops out of the list was removed elsewhere.
    @ObservationIgnored private var discoveredMacIDs: Set<String>?
    /// Macs removed from this phone, against answers already on their way.
    @ObservationIgnored private var removedMacs = RemovedMacs()
    /// A team the user picked in the sidebar: discovery leaves it while it is empty.
    @ObservationIgnored private var pinnedTeamID: String?
    /// What this account last saw (restored at launch, saved as it changes).
    @ObservationIgnored private let snapshots: LiveSnapshotStore
    @ObservationIgnored private var snapshot: LiveSnapshot?
    @ObservationIgnored private var snapshotSavePending = false
    /// Reads the cached rows past each Mac's first screen, after launch (`restoreRest`).
    @ObservationIgnored private var restTask: Task<Void, Never>?
    #if DEBUG
    /// Test-only (compiled out of Release): the Mac the end-of-task hand-off names
    /// (`CMUX_MOBILE_FOCUS_MAC`, cmux-next-ios/scripts/review.sh), remembered as its team's pick once
    /// that team's Macs list it, so the phone focuses the tagged build and not another build of the
    /// same computer. It only picks a Mac, as a tap in the Macs list does: the Mac still decides pairing.
    @ObservationIgnored public var dogfoodFocusMacID: String?
    #endif
    /// The team whose registration, Macs and presence are running or done.
    @ObservationIgnored private var startedTeamID: String?
    /// The team the Feed's items came from. Feed items carry no Mac, so on a switch they
    /// go (the new team's Macs fill it on connect): an old team's ask answered here went to
    /// the new team's Mac and failed, or reached the wrong one.
    @ObservationIgnored private var feedTeamID: String?
    @ObservationIgnored private var feedArchive: FeedArchive?
    @ObservationIgnored private var feedSaveTask: Task<Void, Never>?
    /// The Feed's answers (`FeedStore.actions` is weak: this keeps them alive).
    @ObservationIgnored var feedActions: MultiMacFeedActions?
    /// How long a connected Mac may take to send its workspace list before
    /// the list says it could not load them (with Retry), instead of a
    /// skeleton that never ends.
    static let workspacesDeadline: Duration = .seconds(10)

    /// The personal space id for a user (PROTOCOL.md "Personal space").
    public static func personalTeamID(userID: String) -> String { "personal-\(userID)" }

    public init(
        store: AppStore,
        api: LiveAPI,
        identity: DeviceIdentity,
        userID: String,
        deviceName: String,
        transport: CmuxMobileTransport.TransportKind,
        relayOnly: Bool = false,
        blockUDP: Bool = false,
        dialer: any MacLinkDialer,
        feedStore: FeedStore = .shared,
        keys: PhoneKeys? = nil,
        snapshots: LiveSnapshotStore = .standard,
        secrets: any DeviceSecretStore = KeychainSecretStore(),
        readMarks: FeedReadMarks? = nil,
        pins: MacPins? = nil,
        push: PushKeys? = nil,
        clock: any Clock<Duration> = ContinuousClock(),
        watchesConnectivity: Bool = true
    ) {
        self.secrets = secrets
        ConnectTimeline.shared.mark("coordinator_start")
        self.snapshots = snapshots
        self.store = store
        self.api = api
        self.identity = identity
        self.userID = userID
        self.deviceName = deviceName
        pairing = keys.map {
            LinkPairing(keys: $0, phoneID: identity.link, name: deviceName, pins: pins ?? .forAccount(userID), push: push)
        }
        self.clock = clock
        instants = ClockInstants(clock)
        discovery = MacDiscoveryPoll(clock: clock)
        self.transport = transport
        self.relayOnly = relayOnly
        self.blockUDP = blockUDP
        self.dialer = dialer
        let apiForIncidents = api
        // A headless coordinator (a notification reply on a cold background launch) never watches: its
        // reporter has no file, so it neither sends nor recovers the app's own open incidents.
        incidents = ConnectivityIncidentReporter(
            file: watchesConnectivity ? ConnectivityIncidentReporter.file(account: userID) : nil, clock: clock,
            watches: watchesConnectivity,
            check: ConnectivityIncidentReporter.liveCheck(serviceBase: api.baseURL),
            send: { incident, simulations, app in
                try await apiForIncidents.reportConnectivityIncident(incident, simulations: simulations, app: app)
            })
        incidents.simulations = Self.simulations(relayOnly: relayOnly, blockUDP: blockUDP)
        self.feedStore = feedStore
        let apiForLink = api
        idleSession = MacSession(
            macID: "", name: "", link: LinkController(transport: transport, dialer: dialer, clock: clock,
                                                     accessToken: { try await apiForLink.accessToken($0) }),
            deviceID: identity.link, deviceName: deviceName, feedStore: feedStore)
        // The default Chief is the account's Cloud Chief (same sign-in);
        // the Mac Chief below stays reachable beside it.
        // In the same build space as the mobile service (a dev build's own cloud data).
        ChiefSources.shared.start(userID: userID, config: .current(buildSpace: api.buildSpace)) { try await apiForLink.accessToken($0) }
        // The Feed as this phone last saw it. A team is not known until the
        // account/team snapshot or the account list arrives, so the legacy
        // account-only archive is never shown under an arbitrary team.
        feedStore.useReadMarks(readMarks ?? .forAccount(userID))
        feedStore.onItemsChange = nil
        feedStore.onKnownData = nil
        feedStore.resetKnownData()
        feedStore.replaceAll([])
        feedStore.onItemsChange = { [weak self] items in
            self?.scheduleFeedSave()
            for session in self?.sessions.values ?? [:].values { session.terminalFeed.itemsChanged(items) }
        }
        feedStore.onKnownData = { [weak self] in self?.scheduleFeedSave() }
        let feedActions = MultiMacFeedActions(coordinator: self)
        self.feedActions = feedActions
        feedStore.actions = feedActions
        feedStore.syncState = .connecting
        store.workspaces = []
        store.resetGroupEdits()
        store.tracksMacData = true
        store.macData = [:]
        store.macConnection = [:]
        store.teamDataState = .loading
        let buildSource: (AgentSessionSummary) -> any AgentSessionSource = { [weak self] summary in
            guard let self else { return UnboundAgentSource(summary: summary, macName: nil) }
            // The tab's own Mac (tab ids repeat across Macs); a chat of a Mac
            // whose link is closed opens it, and is rebuilt once its tree lists the tab.
            let owner = self.session(tabID: summary.id, macID: summary.macID.isEmpty ? nil : summary.macID)
            if !summary.macID.isEmpty, owner?.link.target == nil { self.touch(summary.macID) }
            var scoped = summary
            scoped.accountID = self.userID
            // A terminal tab's chat face names its acpmux session itself (Toggle Terminal and Chat).
            if let owner, let session = summary.acpmuxSessionID {
                return self.agentSource(owner, session: session, summary: scoped)
            }
            let key = AgentSessionDirectory.key(id: summary.id, macID: summary.macID)
            // A tab of a workspace this phone is still creating (New Task, New Agent Chat): the Mac
            // is starting its chat, which opens under the Mac's own tab id once listed. It loads
            // meanwhile; it has not "not started".
            if self.store.pendingWorkspaceIDs.contains(where: { self.store.workspace(id: $0)?.tabs.contains { $0.id == summary.id } == true }) {
                return StartingAgentSource(summary: scoped)
            }
            // The Mac's tree has not come yet (a relaunch, the link still opening): the tab is not
            // known to be unbound. Its kept session opens at once (and catches up when the link
            // comes); with none kept, the chat loads instead of saying it hasn't started.
            if let owner, owner.tree == nil {
                let keptKey = AgentTranscriptCache.key(accountID: scoped.accountID, macID: summary.macID, tabID: summary.id)
                // The kept session from memory, else the chat's small head file in this turn (no
                // "Loading chat…" first frame for a chat this phone holds).
                if let keptKey, let keptSession = self.transcriptCache?.cached(keptKey)?.sessionID ?? self.keptSessionIDs[key]
                    ?? self.transcriptCache?.firstScreen(keptKey)?.sessionID {
                    self.sourcedSessions[key] = (tabID: summary.id, macID: summary.macID, session: keptSession, provisional: true)
                    return self.agentSource(owner, session: keptSession, summary: scoped)
                }
                self.sourcedSessions[key] = (tabID: summary.id, macID: summary.macID, session: nil, provisional: true)
                return PendingAgentSource(summary: scoped, cache: self.transcriptCache, keptKey: keptKey) { [weak self, weak owner] sessionID in
                    // Its kept records are read: the chat opens on its session's source.
                    guard self?.sourcedSessions[key]?.provisional == true, let owner, owner.tree == nil else { return }
                    self?.keptSessionIDs[key] = sessionID
                    self?.sourcedSessions[key] = nil
                    self?.chatSessionChanged(id: summary.id, macID: summary.macID)
                }
            }
            // A tab this phone just bound opens on its chat before the tree lists the bind (which then changes nothing).
            let listed = owner?.tree?.agentTabs[summary.id]?.session
            if listed != nil { self.boundHere[key] = nil }
            let session = listed ?? self.boundHere[key]
            self.sourcedSessions[key] = (tabID: summary.id, macID: summary.macID, session: session, provisional: false)
            guard let owner, let session else {
                // The first send starts the chat in this tab, on the tab's own Mac.
                let macName: String? = owner?.name ?? self.link.target?.name
                let start: UnboundAgentSource.Start? = owner.map { self.unboundStart($0, summary: summary, key: key) }
                return UnboundAgentSource(summary: summary, macName: macName, start: start)
            }
            return self.agentSource(owner, session: session, summary: scoped)
        }
        AgentSessionDirectory.shared.makeSource = { [weak self] summary in
            let source = buildSource(summary)
            self?.handOverHeldPrompts(key: AgentSessionDirectory.key(id: summary.id, macID: summary.macID), to: source)
            return source
        }
        restoreSnapshot()
        // Which chat each terminal agent shows, read now: an offline relaunch opens on its kept turns.
        if let kept = transcriptCache?.terminalChats { Task { await kept.load() } }
        watchNetwork()
    }

    /// A tab this phone just bound to the chat it started (its first send), until the Mac's tree
    /// lists the bind: its chat opens on that session meanwhile. Gone with the tab's store.
    @ObservationIgnored var boundHere: [String: String] = [:]

    /// The first message of a chat this phone just started in tab `summary`: the tab's chat is
    /// rebuilt on `session` now (its store reads the session's source), and the message goes as
    /// that chat's own Send, so a failure to send it hands the draft back in the chat on screen.
    private func unboundStart(_ owner: MacSession, summary: AgentSessionSummary, key: String) -> UnboundAgentSource.Start {
        { [weak self, weak owner] (text: String, attachments: [AgentAttachment]) async throws in
            guard let self, let owner else { throw WorkspaceCreationError("Not connected", isForPerson: true) }
            let session = try await owner.creation.startUnboundChat(tabID: summary.id, harness: summary.harness)
            self.sendFirst(text, attachments: attachments, session: session, summary: summary, key: key)
        }
    }

    private func sendFirst(_ text: String, attachments: [AgentAttachment], session: String,
                           summary: AgentSessionSummary, key: String) {
        boundHere[key] = session
        sourcedSessions[key] = nil
        AgentSessionDirectory.shared.invalidate(id: summary.id, macID: summary.macID)
        AgentSessionDirectory.shared.store(for: summary).send(prompt: text, attachments: attachments)
    }

    /// A tab's new chat source: a loading one keeps the earlier loading source's held prompts; a
    /// real one gets them, sent in order after its store subscribes (a send while the chat
    /// loaded is not bounced back with "Send again"; the real source holds it for a blip as
    /// usual, and returns it to the composer with why if the Mac stays away).
    func handOverHeldPrompts(key: String, to source: any AgentSessionSource) {
        let earlier = pendingSources.removeValue(forKey: key)
        let held = earlier?.takeHeld() ?? []
        if let pending = source as? PendingAgentSource {
            pendingSources[key] = pending
            for (intent, at) in held { pending.hold(intent, since: at) }
            return
        }
        guard !held.isEmpty else { return }
        Task { @MainActor in
            for (intent, _) in held { source.send(intent) }
        }
    }

    /// The tab's chat opens on another source (the Mac's tree bound it, its kept records were
    /// read): its store is built again from `makeSource`. A chat still holding prompts sent while
    /// it loaded gets that store now, not when it is next opened: the prompts go to its new
    /// source (sent, or back in its composer with why) instead of expiring into a store that
    /// is gone, which would lose them.
    func chatSessionChanged(id: String, macID: String) {
        AgentSessionDirectory.shared.invalidate(id: id, macID: macID)
        let key = AgentSessionDirectory.key(id: id, macID: macID)
        guard let pending = pendingSources[key], !pending.held.isEmpty else { return }
        _ = AgentSessionDirectory.shared.store(for: pending.summary)
    }

    /// The Mac's acpmux source for `session`; one that drops a kept copy too old to catch up from
    /// gets its chat's store built again (``AcpmuxSessionSource/onReset``).
    private func agentSource(_ owner: MacSession, session: String, summary: AgentSessionSummary) -> AcpmuxSessionSource {
        let source = owner.acpmux.source(sessionID: session, summary: summary)
        source.onReset = { AgentSessionDirectory.shared.invalidate(id: summary.id, macID: summary.macID) }
        return source
    }

    // MARK: Network changes

    #if DEBUG
    private static var networkProbeStarted = false

    /// DEBUG: launched with `CMUX_MOBILE_NETWORK_PROBE=roam` (or `loss`, no roam),
    /// measure a simulated network change once, `CMUX_MOBILE_NETWORK_PROBE_DELAY`
    /// seconds (default 3) after the first link comes up, and log the result
    /// as `network_probe {json}`.
    func runNetworkProbeIfAsked(_ link: any MacLink) {
        guard !Self.networkProbeStarted, let mode = ProcessInfo.processInfo.environment["CMUX_MOBILE_NETWORK_PROBE"],
              let probing = link as? any NetworkChangeProbing else { return }
        Self.networkProbeStarted = true
        let roam = mode != "loss"
        let delay = Double(ProcessInfo.processInfo.environment["CMUX_MOBILE_NETWORK_PROBE_DELAY"] ?? "") ?? 3
        let clock = clock
        Task.detached {
            try? await clock.sleep(for: .seconds(delay))
            log.notice("network_probe start roam=\(roam, privacy: .public)")
            let result = await probing.networkChangeProbe(roam: roam, windowMillis: roam ? 3000 : 20000)
            log.notice("network_probe \(result, privacy: .public)")
        }
    }
    #endif

    private func watchNetwork() {
        let monitor = NetworkPathMonitor()
        networkTask = Task { [weak self] in
            for await event in monitor.events {
                guard let self else { return }
                self.networkPathChanged(event)
            }
        }
    }

    /// The phone moved to another network or lost it: links roam in place
    /// (no redial), presence reconnects.
    func networkPathChanged(_ event: NetworkPathEvent) {
        switch event {
        case .lost:
            log.info("network lost")
            incidents.network(nil)
            ConnectTimeline.shared.mark("network_lost")
            // The offline banner and the Workspaces page's offline wording (CMUX-49).
            if !store.isOffline { store.isOffline = true }
        case .changed(let path):
            log.info("network changed: \(path, privacy: .public)")
            incidents.network(Self.networkKind(path))
            if store.isOffline { store.isOffline = false }
            lastPathNudge = instants.now()
            presence?.kick()
            discovery.wake()
            guard let teamID = registeredTeamID else { return }
            // Every link roams in place (one signaling socket carries them all);
            // one controller asks the dialer, the others only redial a failed link.
            focused.link.networkChanged(baseURL: api.baseURL, teamID: teamID, deviceID: identity.link)
            for session in sessions.values where session !== focused {
                session.link.send(.networkChanged)
            }
        }
    }

    /// The presence socket's hello after an outage proves the cmux service is reachable
    /// again: every waiting or dialing link dials now, not at the end of its backoff step
    /// or a dial still hanging on the dead path. This is the Wi-Fi-back signal when iOS
    /// reports no path change (the radio stayed "satisfied" through an elevator). A kick's
    /// own reconnect (down a moment) and a path change just handled do not count.
    private func presenceReturned() {
        guard let lostAt = presenceLostAt else { return }
        presenceLostAt = nil
        let now = instants.now()
        guard now - lostAt >= Self.presenceOutageMin else { return }
        if let nudged = lastPathNudge, now - nudged < Self.presenceOutageMin { return }
        log.info("presence back after an outage: links redial")
        ConnectTimeline.shared.mark("presence_back")
        if store.isOffline { store.isOffline = false }
        for session in sessions.values { session.link.send(.networkChanged) }
    }

    /// Presence down at least this long before its return redials the links.
    static let presenceOutageMin: Duration = .seconds(3)

    // MARK: Warm start

    /// Launch with a snapshot: show the space, its Macs and their last-known
    /// workspaces (marked cached), warm the signaling socket, and dial the
    /// Mac this phone last reached, all before Stack's team list or the
    /// service's Mac list answers. Registration, Macs and presence start at
    /// once in the background and correct anything that changed.
    ///
    /// Only each Mac's first screen of rows is read here, on the way to the first frame: a Mac
    /// with 5,000 cached workspaces paints as fast as one with 20 (`workspaces_cold_paint_from_cache`
    /// in cmux-next-ios/design/instant-perf.md). The rest is read off the main thread and joins
    /// below them (`restoreRest`).
    private func restoreSnapshot() {
        guard let snapshot = snapshots.loadFirstScreen(accountID: userID) else { return }
        self.snapshot = snapshot
        // A chat opened before its workspace is listed (a notification while the list loads, a
        // row past the first screen) draws from the saved copy, not "Loading chat…".
        store.savedWorkspace = { [weak self] id in self?.savedWorkspace(id: id) }
        store.teams = [Team(id: snapshot.teamID, name: snapshot.teamName, macs: snapshot.macs)]
        store.activeTeamID = snapshot.teamID
        var workspaces: [Workspace] = []
        var total = 0
        for mac in snapshot.macs {
            guard let saved = snapshot.workspaces[mac.id] else { continue }
            workspaces += saved.workspaces
            total += saved.total
            // Rows already in the Feed at launch whose tab closed before the app last saw the Mac
            // go before it answers (the Mac's own tree then judges every row).
            feedStore.setOpenTabs(FeedOpenTabs(workspaces: saved.workspaces, complete: false), macID: mac.id)
            store.handleMacData(.restored(count: saved.total, savedAt: saved.savedAt), macID: mac.id)
        }
        store.workspaces = workspaces
        store.teamDataState = .loaded
        ConnectTimeline.shared.mark("snapshot_restored", detail: "\(workspaces.count) of \(total) workspaces")
        if snapshot.workspaces.values.contains(where: { !$0.isComplete }) {
            let snapshots = snapshots
            let userID = userID
            restTask = Task { [weak self] in
                let rest = await snapshots.loadRest(snapshot, accountID: userID)
                self?.restoreRest(rest)
            }
        }
        // The link device was registered in this space when the snapshot was
        // saved (registration is an upsert and survives), so the socket and
        // the dial need not wait for it.
        registeredTeamID = snapshot.teamID
        idleSession.link.prewarm(baseURL: api.baseURL, teamID: snapshot.teamID, deviceID: identity.link)
        retarget()
        // Launch dials the focused Mac now, whatever the snapshot last heard from
        // presence: a cached "offline" waits for a real dial to say so.
        if let focusedMacID { sessions[focusedMacID]?.link.send(.open) }
        startedTeamID = snapshot.teamID
        activateFeed(for: snapshot.teamID)
        teamTask = Task { [weak self] in await self?.startTeam(snapshot.teamID, warm: true) }
    }

    /// The rest of the saved rows, read at most once by ``savedWorkspace(id:)`` ahead of `restoreRest`.
    @ObservationIgnored private var savedRestRead: [String: LiveSnapshot.MacWorkspaces]?

    /// The workspace `id` as the snapshot on disk saved it: the first screen's rows, else the rest
    /// (read now, once, when `restoreRest` has not landed yet). Nil when it was never saved.
    func savedWorkspace(id: String) -> Workspace? {
        guard let snapshot, !stopped, snapshot.teamID == store.activeTeamID else { return nil }
        for list in snapshot.workspaces.values {
            if let found = list.workspaces.first(where: { $0.id == id }) { return found }
        }
        guard snapshot.workspaces.values.contains(where: { !$0.isComplete }) else { return nil }
        let rest = savedRestRead ?? snapshots.restNow(snapshot, accountID: userID)
        savedRestRead = rest
        for list in rest.values {
            if let found = list.workspaces.first(where: { $0.id == id }) { return found }
        }
        return nil
    }

    /// The rest of the cached rows, read after the first screen: each Mac still showing exactly
    /// the rows restored at launch gets its whole cached list. The new rows sort below the
    /// first screen's (the head holds the list's first rows), so nothing on screen moves. A Mac
    /// that answered since (or went live and dropped again) keeps what it has.
    func restoreRest(_ rest: [String: LiveSnapshot.MacWorkspaces]) {
        restTask = nil
        guard !stopped else { return }
        var added = 0
        for (macID, list) in rest {
            guard let current = snapshot?.workspaces[macID], !current.isComplete, current.tailToken == list.tailToken,
                  current.savedAt == list.savedAt else { continue }
            snapshot?.workspaces[macID] = list
            guard store.macData[macID]?.source == .cache(savedAt: list.savedAt) else { continue }
            store.replaceWorkspaces(macID: macID, with: list.workspaces)
            feedStore.setOpenTabs(FeedOpenTabs(workspaces: list.workspaces, complete: false), macID: macID)
            if list.total != current.total { store.handleMacData(.restored(count: list.total, savedAt: list.savedAt), macID: macID) }
            added += list.workspaces.count - current.workspaces.count
        }
        ConnectTimeline.shared.mark("snapshot_rest_restored", detail: "\(added) workspaces")
    }

    /// Saves what the phone sees now (coalesced to one write per main-queue turn).
    func scheduleSnapshotSave() {
        guard !snapshotSavePending else { return }
        snapshotSavePending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            snapshotSavePending = false
            saveSnapshot()
        }
    }

    private func saveSnapshot() {
        guard let team = store.activeTeam, registeredTeamID == team.id else { return }
        var saved = snapshot?.teamID == team.id ? snapshot?.workspaces ?? [:] : [:]
        let macIDs = Set(team.macs.map(\.id))
        saved = saved.filter { macIDs.contains($0.key) }
        for mac in team.macs where store.macData[mac.id]?.source == .live {
            saved[mac.id] = .init(workspaces: store.workspaces.filter { $0.macID == mac.id && !store.isPending($0.id) }, savedAt: Date())
        }
        let next = LiveSnapshot(teamID: team.id, teamName: team.name, macs: team.macs,
                                linkedMacID: focusedMacID ?? snapshot?.linkedMacID, workspaces: saved)
        guard next != snapshot else { return }
        snapshot = next
        snapshots.save(next, accountID: userID)
    }

    // MARK: Teams

    private static func personalTeam(for userID: String) -> AppStore.AccountTeam {
        AppStore.AccountTeam(id: personalTeamID(userID: userID), name: "Personal")
    }

    private var personal: AppStore.AccountTeam { Self.personalTeam(for: userID) }

    /// Applies the account's teams (or the personal space) and starts the
    /// active one. The personal space stays listed next to Stack teams while
    /// one of the account's Macs is in it. Starts Mac discovery.
    public func applyAccountTeams(_ teams: [AppStore.AccountTeam], selectedID: String?) {
        Self.showAccountTeams(teams, selectedID: selectedID, userID: userID, in: store)
        activeTeamChanged()
        for team in store.teams { loadPrefs(team.id) }
        discovery.start { [weak self] in await self?.lookForMacs() }
    }

    /// Populate the sidebar without treating cached memberships as a new service answer.
    public static func showAccountTeams(_ teams: [AppStore.AccountTeam], selectedID: String?, userID: String, in store: AppStore) {
        let personal = personalTeam(for: userID)
        var list = teams.isEmpty ? [personal] : teams
        let keepsPersonal = store.activeTeamID == personal.id || store.teams.contains(where: { $0.id == personal.id && !$0.macs.isEmpty })
        if !teams.isEmpty, keepsPersonal { list.append(personal) }
        // A team the phone already shows (picked, or followed to a Mac) stays active.
        let keep = list.contains { $0.id == store.activeTeamID } ? store.activeTeamID : selectedID
        store.applyLiveTeams(list, selectedID: keep)
    }

    /// The user chose their personal space (setup's "Choose a space"): it
    /// joins the list if it wasn't there and becomes the active space.
    public func selectPersonal() {
        if !store.teams.contains(where: { $0.id == personal.id }) {
            let list = store.teams.map { AppStore.AccountTeam(id: $0.id, name: $0.name) } + [personal]
            store.applyLiveTeams(list, selectedID: personal.id)
        }
        store.selectTeam(personal.id)
        activeTeamChanged(byUser: true)
    }

    /// Restores the team's Feed before its fresh membership and service discovery arrive.
    public func restoreFeedForActiveTeam() {
        if !store.activeTeamID.isEmpty { activateFeed(for: store.activeTeamID) }
    }

    /// Coalesce a burst of events. The latest rows go to the team active when the write began.
    private func scheduleFeedSave() {
        guard !stopped, feedArchive != nil, feedSaveTask == nil,
              feedStore.hasKnownData || !feedStore.items.isEmpty else { return }
        feedSaveTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            flushFeedSave()
        }
    }

    private func flushFeedSave() {
        guard let pending = feedSaveTask else { return }
        pending.cancel()
        feedSaveTask = nil
        feedArchive?.saveInBackground(feedStore.items)
    }

    /// Activates the persisted Feed for one account/team. During a switch the
    /// old callbacks are muted so replacing rows cannot save them into the new
    /// archive or turn an uncached team into a known-empty snapshot.
    private func activateFeed(for teamID: String) {
        guard feedTeamID != teamID || feedArchive == nil else { return }
        let archive = FeedArchive.forAccount(userID, teamID: teamID)
        flushFeedSave()
        let itemsChange = feedStore.onItemsChange
        let knownData = feedStore.onKnownData
        feedStore.onItemsChange = nil
        feedStore.onKnownData = nil
        feedArchive = archive
        feedTeamID = teamID
        feedStore.resetKnownData()
        feedStore.syncState = .connecting
        feedStore.useSpill(.forThisRun("feed", scope: UUID().uuidString))
        let snapshot = archive.loadIfPresent()
        feedStore.replaceAll(snapshot ?? [])
        if snapshot != nil { feedStore.markKnown() }
        feedStore.onItemsChange = itemsChange
        feedStore.onKnownData = knownData
    }

    /// Call after `store.selectTeam`: re-registers, reloads Macs, re-targets
    /// the link. `byUser` marks a sidebar pick, which discovery respects.
    public func activeTeamChanged(byUser: Bool = false) {
        let teamID = store.activeTeamID
        if byUser { pinnedTeamID = teamID }
        guard !teamID.isEmpty else { return }
        guard teamID != registeredTeamID, teamID != startedTeamID else {
            activateFeed(for: teamID)
            return
        }
        startedTeamID = teamID
        teamTask?.cancel()
        presence?.stop()
        presence = nil
        registeredTeamID = nil
        store.teamDataState = .loading
        closeAllSessions()
        restoreTeamCache(teamID)
        activateFeed(for: teamID)
        teamTask = Task { [weak self] in await self?.startTeam(teamID) }
    }

    /// A switch to a team this phone showed before (on this launch or an earlier one) draws its
    /// last rows at once, as a launch does, and the team's Macs then correct them in place: the
    /// list draws placeholder rows only for a team it never listed. Leo, 2026-11-24: "holy shit
    /// this is a huge problem in ios... wer need to chase all these placeholders doen and prevent
    /// them". A Mac whose rows the store still holds (shown earlier in this launch) keeps them.
    private func restoreTeamCache(_ teamID: String) {
        guard snapshot?.teamID != teamID, let cached = snapshots.loadFirstScreen(accountID: userID, teamID: teamID) else { return }
        snapshot = cached
        if let team = store.teams.first(where: { $0.id == teamID }), team.macs.isEmpty {
            store.setMacs(cached.macs, teamID: teamID)
        }
        var restored = 0
        for (macID, saved) in cached.workspaces
        where (store.macData[macID]?.source ?? .none) == .none && !store.workspaces.contains(where: { $0.macID == macID }) {
            store.replaceWorkspaces(macID: macID, with: saved.workspaces)
            store.handleMacData(.restored(count: saved.total, savedAt: saved.savedAt), macID: macID)
            restored += saved.workspaces.count
        }
        ConnectTimeline.shared.mark("team_snapshot_restored", detail: "\(restored) workspaces")
        guard cached.workspaces.values.contains(where: { !$0.isComplete }) else { return }
        let snapshots = snapshots
        let userID = userID
        restTask?.cancel()
        restTask = Task { [weak self] in
            let rest = await snapshots.loadRest(cached, accountID: userID)
            self?.restoreRest(rest)
        }
    }

    /// Registers both device ids, then loads the Macs and starts presence.
    /// `warm`: the link is already dialing in this team from the snapshot,
    /// so nothing on screen is reset while this runs.
    private func startTeam(_ teamID: String, warm: Bool = false) async {
        do {
            // One round trip: both registrations, this team's Macs and the account's Macs.
            let asked = removedMacs.mark
            if let boot = try await api.bootstrap(teamID: teamID, devices: [
                (identity.link, "phone", deviceName), (identity.presence, "phone", "\(deviceName) (presence)"),
            ]) {
                ConnectTimeline.shared.mark("registered", detail: "bootstrap")
                guard !Task.isCancelled, store.activeTeamID == teamID else { return }
                if !warm { idleSession.link.prewarm(baseURL: api.baseURL, teamID: teamID, deviceID: identity.link) }
                registeredTeamID = teamID
                push.attach(api: api, deviceID: identity.link)
                checkRelay()
                ConnectTimeline.shared.mark("macs_loaded", detail: "\(boot.macs.count)")
                applyMacs(boot.macs, teamID: teamID, askedAt: asked)
                store.teamDataState = .loaded
                if let mine = boot.myMacs { applyDiscovered(mine, askedAt: asked) }
                startPresence(teamID)
                return
            }
            // A service before 0.8.0: the separate calls, both registrations at once.
            async let linkDevice: Void = api.registerDevice(id: identity.link, kind: "phone", name: deviceName, teamID: teamID)
            async let presenceDevice: Void = api.registerDevice(id: identity.presence, kind: "phone", name: "\(deviceName) (presence)", teamID: teamID)
            try await linkDevice
            if !warm {
                // The link device is registered: warm its socket while the rest loads.
                idleSession.link.prewarm(baseURL: api.baseURL, teamID: teamID, deviceID: identity.link)
            }
            try await presenceDevice
            ConnectTimeline.shared.mark("registered")
            guard !Task.isCancelled, store.activeTeamID == teamID else { return }
            registeredTeamID = teamID
            push.attach(api: api, deviceID: identity.link)
            checkRelay()
            let askedForMacs = removedMacs.mark
            let macs = try await api.macs(teamID: teamID)
            guard !Task.isCancelled, store.activeTeamID == teamID else { return }
            ConnectTimeline.shared.mark("macs_loaded", detail: "\(macs.count)")
            applyMacs(macs, teamID: teamID, askedAt: askedForMacs)
            store.teamDataState = .loaded
            log.info("team \(teamID, privacy: .private) registered, \(macs.count, privacy: .public) Macs")
            startPresence(teamID)
        } catch {
            guard !Task.isCancelled else { return }
            log.error("team start failed: \(String(describing: error), privacy: .public)")
            // Failed either way: a warm start's cached rows stay on screen
            // (WorkspacesLaunchState keeps them, with no connection text);
            // the retry below catches up.
            store.teamDataState = .failed
            // Try again on its own (the list's Retry also works).
            do { try await clock.sleep(for: .seconds(5)) } catch { return }
            guard store.activeTeamID == teamID, registeredTeamID == nil || warm else { return }
            await startTeam(teamID, warm: warm)
        }
    }

    private func startPresence(_ teamID: String) {
        let listener = PresenceListener(api: api, teamID: teamID, deviceID: identity.presence, clock: clock) { [weak self] update in
            self?.presenceUpdate(update, teamID: teamID)
        }
        listener.backgrounded = isBackgrounded
        presence = listener
        listener.start()
    }

    /// Retry after a failed team load (the Workspaces Retry button).
    public func retry() {
        registeredTeamID = nil
        startedTeamID = nil
        activeTeamChanged()
    }

    private func presenceUpdate(_ update: PresenceListener.Update, teamID: String) {
        guard store.activeTeamID == teamID else { return }
        switch update {
        case .connected(let connected):
            let was = presenceConnected
            presenceConnected = connected
            if was && !connected { presenceLostAt = instants.now() }
            if connected && !was { presenceReturned() }
        case .snapshot(let macs):
            applyMacs(macs, teamID: teamID, askedAt: removedMacs.mark)
        case .mac(let mac) where mac.removed == true:
            forgetMac(mac.deviceId)
        case .mac(let mac):
            // A Mac came or went: discovery looks now (another team's Mac to follow, or the
            // fast wait again) instead of at its backed-off cadence.
            discovery.wake()
            var current = store.teams.first { $0.id == teamID }?.macs ?? []
            let known = current.first { $0.id == mac.deviceId }
            // A Worker that predates machine ids sends none: keep the one the list had. A
            // presence frame names no owner; the caller's hub carries only the caller's own
            // Macs (0.10.0), so a Mac new to the list is the caller's.
            let owner = othersMacs.contains(mac.deviceId) ? known?.ownerUserID : (known?.ownerUserID ?? userID)
            let device = MacDevice(id: mac.deviceId, name: mac.name, isOnline: mac.online, lastSeenAt: mac.lastSeenDate,
                                   ownerUserID: owner, machineID: mac.machineId ?? known?.machineID, quietMs: mac.quietMs)
            if let index = current.firstIndex(where: { $0.id == mac.deviceId }) { current[index] = device } else { current.append(device) }
            store.setMacs(current, teamID: teamID)
            let session = sessions[mac.deviceId]
            let generationBefore = session?.link.dialGeneration
            retarget()
            // The linked Mac's signaling socket is up (again): its host may
            // have restarted under the live link. Probe it now instead of at
            // the next heartbeat (termfix-r13 D2b), or dial now if waiting.
            // Only when retarget() did not just dial (a Mac back from offline):
            // a second dial at once would abandon the first, whose offer the
            // host may already be answering (r13 review).
            if mac.online, let session, session.link.target?.macID == mac.deviceId, session.link.dialGeneration == generationBefore {
                session.link.send(.macSignaled)
            }
        }
    }

    /// Macs registered by another member (a shared team): listed, never
    /// dialed. Protocol v1 admits only the Mac owner's own phones.
    /// Display-only peer records for Settings. A coordinator retains its own account's cache handle.
    public var terminalSizingPeers: TerminalSizingPeers?

    @ObservationIgnored private var othersMacs: Set<String> = []

    /// A Mac its owner deleted (here or on another device): gone from every
    /// team with its cached workspaces and connection state. When the link
    /// was on it, the link moves to another Mac (or to none) at once, so
    /// nothing keeps saying "Connecting…" to a Mac that no longer exists.
    func forgetMac(_ id: String) {
        let linked = sessions[id]?.link.target != nil
        // Its link closes first, and its phase change must not write data for it back.
        closeSession(id)
        parkedTerminals[id] = nil
        // Its tab cards go too: a Mac added again under this id starts from a whole manifest.
        tabs.forget(macID: id)
        feedStore.forgetOpenTabs(macID: id)
        // Its banner, pairing prompt and Chief go with it (retarget may focus another Mac).
        if focusedMacID == id { setFocus(nil) }
        lastShown[id] = nil
        let known = store.forgetMac(id)
        othersMacs.remove(id)
        terminalSizingPeers?.forget(id)
        discoveredMacIDs?.remove(id)
        previouslyOnline = previouslyOnline?.filter { !$0.hasPrefix("\(id)\u{0}") }
        if snapshot?.linkedMacID == id { snapshot?.linkedMacID = nil }
        retarget()
        scheduleSnapshotSave()
        if known || linked { onMacRemoved?(id) }
    }

    private func applyMacs(_ macs: [LiveAPI.Mac], teamID: String, askedAt: Int) {
        let macs = removedMacs.filter(macs, askedAt: askedAt, id: \.deviceId)
        for mac in macs {
            if let owner = mac.ownerUserId, owner != userID { othersMacs.insert(mac.deviceId) } else { othersMacs.remove(mac.deviceId) }
        }
        let devices = macs.map { MacDevice(id: $0.deviceId, name: $0.name, isOnline: $0.online, lastSeenAt: $0.lastSeenDate,
                                           ownerUserID: $0.ownerUserId, machineID: $0.machineId, quietMs: $0.quietMs) }
        store.setMacs(devices, teamID: teamID)
        terminalSizingPeers?.replace(teamID: teamID, devices: devices, accountID: userID)
        #if DEBUG
        if let id = dogfoodFocusMacID, macs.contains(where: { $0.deviceId.lowercased() == id.lowercased() }) {
            UserDefaults.standard.set(id, forKey: "cmuxMobile.live.mac.\(teamID)")
            dogfoodFocusMacID = nil
        }
        #endif
        retarget()
        scheduleSnapshotSave()
    }

    /// Focuses the selected Mac (remembered per team), else the first online
    /// one, and holds a link to each Mac `linkPolicy` keeps.
    func retarget() {
        guard let team = store.activeTeam, registeredTeamID == team.id else { return }
        let remembered = UserDefaults.standard.string(forKey: "cmuxMobile.live.mac.\(team.id)")
            ?? (snapshot?.teamID == team.id ? snapshot?.linkedMacID : nil)
        // The remembered Mac (one this phone picked) is the team's picked Mac: it takes the focus.
        // Every build is listed on its own (``MacRoster``).
        store.setPickedMac(remembered, teamID: team.id)
        let next = LinkMachine.target(in: listedMacs(store.activeTeam ?? team), remembered: remembered, current: focusedMacID)
        // The focused Mac's session exists before the focus moves to it.
        if let next { _ = session(for: next) }
        setFocus(next?.id)
        applyLinks()
    }

    /// The Macs the phone focuses and the screens list: the owner's own, each
    /// build as its own Mac (``MacRoster``).
    private func listedMacs(_ team: Team) -> [MacDevice] {
        MacRoster(team.macs.filter { !othersMacs.contains($0.id) }, preferring: team.pickedMacID).visible
    }

    /// The Macs this phone may link: every listed one (each build is listed as its
    /// own Mac); ``MacLinkPolicy`` picks which of them hold a link.
    private func dialableMacs(_ team: Team) -> [MacDevice] {
        listedMacs(team)
    }

    /// The focused Mac changed: the last one stays linked while it is recent
    /// (`MacLinkPolicy.idleAfter`), and the banner, pairing and Chief follow.
    private func setFocus(_ macID: String?) {
        guard macID != focusedMacID else { return }
        if let old = focusedMacID { lastShown[old] = instants.now() }
        focusedMacID = macID
        appearance.focus(macID: macID)
        if let macID { lastShown[macID] = instants.now() }
        pairingState = focused.pairingState
        chiefFollowsFocus()
        ChiefComputer.shared.macChanged()
        phaseChanged(focused)
    }

    /// Opens a link to every Mac the policy keeps and closes the others.
    func applyLinks(_ dialable: [MacDevice]? = nil) {
        guard let team = store.activeTeam, registeredTeamID == team.id else { return }
        let macs = dialable ?? dialableMacs(team)
        let now = instants.now()
        // nil (Workspaces, the Feed): every listed Mac.
        let showing = showingMacs ?? Set(listedMacs(team).map(\.id))
        for id in showing { lastShown[id] = now }
        for (id, session) in sessions { session.link.onScreen = showing.contains(id) }
        // A live link that presence briefly calls offline (a signaling reset) ranks as online:
        // the cap never closes it for that.
        let ranked = macs.map { mac -> MacDevice in
            guard !mac.isOnline, sessions[mac.id]?.link.phase.isConnected == true else { return mac }
            var live = mac
            live.isOnline = true
            return live
        }
        let decision = linkPolicy.decide(macs: ranked, focused: focusedMacID, showing: showing, lastShown: lastShown, now: now)
        for mac in macs where decision.linked.contains(mac.id) {
            let session = session(for: mac)
            session.name = mac.name
            session.link.send(.target(LinkMachine.Target(macID: mac.id, name: mac.name, isOnline: mac.isOnline)))
        }
        for (id, session) in sessions where !decision.linked.contains(id) && session.link.target != nil {
            log.info("link to \(session.name, privacy: .private) idle: closing it")
            session.link.send(.target(nil))
        }
        expiryTask?.cancel()
        expiryTask = nil
        if let expiry = decision.nextExpiry {
            let clock = clock
            let wait = max(expiry - now, .milliseconds(1))
            expiryTask = Task { [weak self] in
                do { try await clock.sleep(for: wait) } catch { return }
                self?.applyLinks()
            }
        }
    }

    /// The screens show these Macs' data now (the Workspaces list, the Feed,
    /// a workspace of one Mac); nil: every Mac. Macs no longer shown keep
    /// their links for `linkPolicy.idleAfter`, then close; a Mac shown again
    /// is dialed then (lazy links).
    public func showing(macIDs: Set<String>?) {
        guard macIDs != showingMacs else { return }
        let now = instants.now()
        for id in showingMacs ?? Set(sessions.keys) { lastShown[id] = now }
        showingMacs = macIDs
        applyLinks()
    }

    /// The session for `mac`, made on first use with its own link.
    private func session(for mac: MacDevice) -> MacSession {
        if let session = sessions[mac.id] { return session }
        let apiForLink = api
        let controller = LinkController(transport: transport, relayOnly: relayOnly, blockUDP: blockUDP, dialer: dialer, clock: clock,
                                        accessToken: { try await apiForLink.accessToken($0) })
        if isBackgrounded { controller.send(.background) }
        let session = MacSession(macID: mac.id, name: mac.name, link: controller, deviceID: identity.link,
                                 deviceName: deviceName, feedStore: feedStore)
        session.acpmux.transcriptCache = transcriptCache
        let macID = mac.id
        session.acpmux.onStall = { [weak self] in await self?.recoverAcpmuxChannel(macID: macID) }
        wire(session)
        sessions[mac.id] = session
        if let parked = parkedTerminals.removeValue(forKey: mac.id) {
            // Their state follows this session's link from its first phase change.
            session.terminals = parked.filter { $0.session != nil }
        }
        return session
    }

    /// Closes a Mac's link and forgets its session.
    private func closeSession(_ id: String) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        let kept = session.terminals.filter { $0.session != nil }
        if !kept.isEmpty { parkedTerminals[id] = kept }
        session.pairingRetry?.cancel()
        for relay in session.cloudChats.values { relay.retire() }
        session.cloudChats.removeAll()
        session.link.send(.target(nil))
        // Its data on screen is last-known now, and nothing says it is connected.
        if session.fedData { store.handleMacData(.disconnected(at: Date()), macID: id) }
        store.macConnection[id] = nil
        if store.macLinkStatus[id] != nil { store.macLinkStatus[id] = nil }
        store.macLinkDiagnostics[id] = nil
        session.offlineTask?.cancel()
        session.quietStatusTask?.cancel()
        session.stallTask?.cancel()
        session.workspacesTimeout?.cancel()
        session.acpmux.cancelWaiters()
        // Signed out: the unbind below ends each chat's link, which saves its kept copy; nothing
        // of the account may be written back after sign-out deleted it.
        if stopped { session.acpmux.transcriptCache = nil }
        Task {
            await session.workspaces.bind(nil, macID: "")
            await session.acpmux.bind(nil)
        }
    }

    /// Closes every link (another team, sign-out).
    private func closeAllSessions() {
        for id in Array(sessions.keys) { closeSession(id) }
        focusedMacID = nil
        // The chrome keeps the last Mac's theme (a device look, cached), and no link changes it now.
        appearance.focus(macID: nil)
        pairingState = .idle
        chiefOffline()
        lastShown = [:]
        expiryTask?.cancel()
        expiryTask = nil
        phaseChanged(idleSession)
    }

    /// Moves the focus to a Mac and remembers it for the team (the next
    /// launch focuses it first). Its link opens if it was not up; the other
    /// Macs keep theirs. Nothing changes for a Mac this phone may not dial.
    public func select(macID: String) {
        guard let team = store.activeTeam, canLink(macID: macID) else { return }
        UserDefaults.standard.set(macID, forKey: "cmuxMobile.live.mac.\(team.id)")
        retarget()
    }

    /// Whether this phone may dial the Mac: protocol v1 admits only the
    /// Mac owner's own phones, so a teammate's Mac is listed, never dialed.
    public func canLink(macID: String) -> Bool {
        !othersMacs.contains(macID)
    }

    // MARK: Discovery across spaces

    /// One discovery look; says whether the active team has an online Mac (the poll's cadence).
    private func lookForMacs() async -> Bool {
        await discoverOnce()
        return store.activeTeam?.macs.contains(where: \.isOnline) ?? false
    }

    /// One look at the account's Macs everywhere: shows each in its team and
    /// moves to the team of an online Mac while the active team has none.
    func discoverOnce() async {
        do {
            let asked = removedMacs.mark
            let macs = try await api.myMacs()
            guard !Task.isCancelled else { return }
            applyDiscovered(macs, askedAt: asked)
        } catch {
            guard !Task.isCancelled else { return }
            log.error("Mac discovery failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The account's Macs everywhere (`/me/macs`, or the bootstrap's copy): shows each in its
    /// team and moves to the team of an online Mac while the active team has none.
    private func applyDiscovered(_ macs: [LiveAPI.Mac], askedAt: Int) {
        let macs = removedMacs.filter(macs, askedAt: askedAt, id: \.deviceId)
        // An own Mac the last look listed and this one does not was removed
        // on another device (the Mac app's unpair, another phone).
        let ids = Set(macs.map(\.deviceId))
        for id in (discoveredMacIDs ?? []).subtracting(ids) { forgetMac(id) }
        discoveredMacIDs = ids
        let found = macs.compactMap { mac -> DiscoveredMac? in
            guard let teamID = mac.teamId else { return nil }
            return DiscoveredMac(id: mac.deviceId, name: mac.name, isOnline: mac.online, lastSeenAt: mac.lastSeenDate, teamID: teamID,
                                 ownerUserID: mac.ownerUserId ?? userID, machineID: mac.machineId, quietMs: mac.quietMs)
        }
        store.mergeDiscoveredMacs(found, personal: personal)
        if store.accountMacCount != found.count { store.accountMacCount = found.count }
        if let team = store.teamToFollow(found, previouslyOnline: previouslyOnline, pinnedTeamID: pinnedTeamID) {
            follow(team, macName: found.first { $0.teamID == team.id && $0.isOnline }?.name ?? "Your Mac")
        }
        previouslyOnline = Set(found.filter(\.isOnline).map(\.placement))
        retarget()
    }

    private func follow(_ team: Team, macName: String) {
        log.info("following \(macName, privacy: .private) to team \(team.id, privacy: .private)")
        store.selectTeam(team.id)
        activeTeamChanged()
        followed = Followed(serial: (followed?.serial ?? 0) + 1, teamID: team.id, teamName: team.name, macName: macName)
        onFollow?(team.id)
    }

    /// Looks once per team start whether the service has a TURN relay.
    private func checkRelay() {
        Task { [weak self] in
            guard let self else { return }
            if let ice = try? await self.api.ice() { self.relayAvailable = ice.turn ?? true }
        }
    }

    // MARK: Devices (Settings → Connection) and account

    /// Every Mac and phone of this account.
    public func myDevices() async throws -> [LiveAPI.Device] {
        try await api.myDevices()
    }

    /// This phone's own device ids (link and presence).
    public var ownDeviceIDs: Set<String> { [identity.link, identity.presence] }

    /// Deletes a device of this account; a Mac leaves every list at once.
    public func removeDevice(id: String) async throws {
        do {
            try await api.deleteDevice(id: id)
        } catch let failure as LiveAPI.Failure where failure.status == 404 {
            // Already gone (removed on another device): the outcome the user asked for.
        }
        removedMacs.removed(id)
        forgetMac(id)
        // Its identity pin goes too: a re-added Mac pins its key again.
        (pairing?.pins ?? .standard).forget(id)
        pairing?.push?.forget(mac: id)
    }

    /// Signs Chief question answers for the linked Mac with this phone's
    /// approval key; nil without pairing keys or a paired Mac.
    public func chiefAnswerSigner() -> ChiefAnswerSigner? {
        guard let pairing, let macID = link.target?.macID, focused.pairingState == .paired else { return nil }
        return ChiefAnswerSigner(keys: pairing.keys, macDevice: macID, phoneID: pairing.phoneID)
    }

    /// Account deletion, first step: the service forgets the account's
    /// devices, push tokens and preferences.
    public func deleteAccountData() async throws {
        try await api.deleteMe()
        forgetThisPhone()
    }

    /// Where a notification's session lives: the agent tab bound to it, or
    /// the tab the Mac named. A push includes its Mac's identity, so resolve
    /// that Mac only; the same session or workspace ids on a different Mac
    /// must never open the wrong chat. Links without a Mac keep the global lookup.
    public func destination(sessionID: String?, workspaceID: String?, tabID: String?,
                            macID: String? = nil) -> AgentChatDestination? {
        if let sessionID {
            let found: LiveFeed.Place?
            if let macID {
                found = sessions[macID]?.place(sessionID: sessionID)
            } else {
                found = place(sessionID: sessionID)
            }
            if let found {
                return AgentChatDestination(workspaceID: found.workspaceID, tabID: found.tabID)
            }
        }
        guard let workspaceID, let tabID, let workspace = store.workspace(id: workspaceID),
              (macID == nil || workspace.macID == macID),
              workspace.tabs.contains(where: { $0.id == tabID }) else { return nil }
        return AgentChatDestination(workspaceID: workspaceID, tabID: tabID)
    }

    /// Sign-out: stops discovery, presence and the link.
    public func stop() {
        flushFeedSave()
        stopped = true
        restTask?.cancel()
        restTask = nil
        transcriptCache = nil
        keptSessionIDs = [:]
        pendingSources = [:]
        ChiefSources.shared.stop()
        incidents.stop()
        networkTask?.cancel()
        networkTask = nil
        discovery.stop()
        teamTask?.cancel()
        presence?.stop()
        presence = nil
        registeredTeamID = nil
        startedTeamID = nil
        callMacID = nil
        callHold?.hold.release()
        callHold = nil
        closeAllSessions()
        let link = idleSession.link
        Task { await link.resetWarmState() }
    }

    /// Sign-out: forget every account's snapshot on this device.
    public static func forgetSnapshots(_ snapshots: LiveSnapshotStore = .standard) {
        snapshots.removeAll()
    }

    // MARK: Prefs and invites

    private func loadPrefs(_ teamID: String) {
        Task { [weak self] in
            guard let self, let appearance = try? await self.api.prefs(teamID: teamID).appearance else { return }
            self.store.setAppearance(appearance, for: teamID)
        }
    }

    /// Saves a team's color, emoji and background locally and with `PUT /prefs`.
    public func saveAppearance(_ appearance: TeamAppearance, teamID: String) async throws {
        store.setAppearance(appearance, for: teamID)
        try await api.putPrefs(teamID: teamID, appearance: appearance)
    }

    public func invite(email: String, teamID: String) async throws {
        try await api.invite(teamID: teamID, email: email)
    }

    // MARK: Transport and lifecycle

    public func setTransport(_ transport: CmuxMobileTransport.TransportKind) {
        self.transport = transport
        for session in sessions.values { session.link.send(.transport(transport)) }
    }

    /// Debug relay-only mode (Settings → Developer); a change redials.
    public func setRelayOnly(_ relayOnly: Bool) {
        self.relayOnly = relayOnly
        incidents.simulations = Self.simulations(relayOnly: relayOnly, blockUDP: blockUDP)
        for session in sessions.values { session.link.send(.relayOnly(relayOnly)) }
    }

    /// Debug UDP-blocked mode (Settings → Developer); a change redials.
    public func setBlockUDP(_ blockUDP: Bool) {
        self.blockUDP = blockUDP
        incidents.simulations = Self.simulations(relayOnly: relayOnly, blockUDP: blockUDP)
        for session in sessions.values { session.link.send(.blockUDP(blockUDP)) }
    }

    /// Keep background work usable, but do not trust these links after suspension.
    public func background() {
        isBackgrounded = true
        foregroundedEarly = false
        backgroundedAt = ContinuousClock.now
        incidents.appActive(false)
        // A call's link may have been opened since the call started.
        holdCallLink()
        for session in sessions.values { session.link.send(.background) }
        discovery.pause()
        presence?.backgrounded = true
        #if canImport(CmuxMobileLinkFFI)
        pairRequests.background()
        #endif
    }

    /// The app's process (not a test): the connectivity incident watch follows UIKit's app state,
    /// seeded with it now (a sign-in made in front has no scene change to start it).
    public func followApplicationState() {
        incidents.followApplicationState()
        LinkController.useApplicationBackgroundTasks()
        followForegroundNotification()
        followKeyboard()
    }

    /// The keyboard coming up means a key follows in a few hundred ms: wake the one link it
    /// goes to now (RFD 0142 T2, ``typingLink``). Only that one: every listed Mac is on
    /// screen on the Workspaces list, and a rename sheet there is not typing to all of them.
    func followKeyboard() {
        #if canImport(UIKit)
        guard keyboardObserver == nil else { return }
        keyboardObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.typingLink.prewake() }
        }
        #endif
    }

    /// The link a key typed now goes to: the one Mac on screen (a workspace's terminal or
    /// chat), else the focused Mac's.
    var typingLink: LinkController {
        if let shown = showingMacs, shown.count == 1, let id = shown.first, let session = sessions[id] {
            return session.link
        }
        return focused.link
    }

    /// The return to the app starts the reconnect at UIKit's `willEnterForeground`, before
    /// the first frame is drawn, not at SwiftUI's `scenePhase == .active` after it. Leo,
    /// 2026-11-24, back from another app: "The like multi-second long reattach where like the
    /// entire thing is somehow grayed out and I can't interact with anything at all."
    func followForegroundNotification() {
        #if canImport(UIKit)
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.willEnterForeground() }
        }
        #endif
    }

    /// Back from the background: the links resume now; the scene's `.active` that follows is
    /// then a repeat (``foreground()``).
    func willEnterForeground() {
        guard isBackgrounded else { return }
        foreground()
        foregroundedEarly = true
    }

    /// Before sign-out, while the token works: open connectivity incidents end and are sent.
    public func endIncidentsBeforeSignOut() async {
        await incidents.signOut()
    }

    /// Warms the next dial (signaling socket, ICE servers) without dialing or
    /// touching a live link. Cheap and idempotent: call it as early as the app
    /// knows it will need the Mac (scene about to enter the foreground, a push
    /// woke the app), so the dial that follows skips those round trips.
    public func prewarmLinks() {
        guard let teamID = registeredTeamID else { return }
        idleSession.link.prewarm(baseURL: api.baseURL, teamID: teamID, deviceID: identity.link)
    }

    /// App foreground: keep the links a short suspend left alive, replace stale ones, refresh presence.
    public func foreground() {
        // `willEnterForeground` already resumed this return.
        if foregroundedEarly {
            foregroundedEarly = false
            return
        }
        let away = backgroundedAt.map { ContinuousClock.now - $0 }
        backgroundedAt = nil
        foreground(after: away)
    }

    /// `away` is how long iOS kept the app away; nil (no background seen) redials every link, a connected one kept beside the redial.
    func foreground(after away: Duration?) {
        isBackgrounded = false
        incidents.appActive(true)
        log.info("foreground: \(String(describing: self.link.phase), privacy: .public)")
        // The first activation is the launch itself, already being measured.
        if ConnectTimeline.shared.sinceProcessStart > 5 { ConnectTimeline.shared.begin("foreground") }
        prewarmLinks()
        presence?.backgrounded = false
        presence?.kick()
        discovery.resume()
        // Time away is not outage the person waited through: a link that dropped while the app
        // was away counts its bounds from now, so its terminals stay reattaching (Send queued in
        // the session's hold, no "Mac offline") instead of offline at once (LinkOutageClock).
        let now = instants.now()
        for session in sessions.values where session.linkDownSince != nil { outageRestarted(session, at: now) }
        // How long iOS kept the app away decides whether the links are kept (LinkMachine.shortSuspend).
        for session in sessions.values { session.link.send(away.map { .resumed(after: $0) } ?? .resume) }
        #if canImport(CmuxMobileLinkFFI)
        pairRequests.foreground()
        catchUpOnForeground()
        #endif
    }

}

/// An agent tab whose Mac has not sent its tree yet (a relaunch, the link still opening), so
/// whether it has a session is not known: the chat loads (``AgentSessionSource/loadsHistory``)
/// instead of showing the new-chat screen or saying the agent hasn't started. When the phone
/// kept the chat's records on disk, `onKept` runs once they are read (the coordinator then opens
/// the chat on that session's source, which shows them); the Mac's tree rebuilds it either way.
@MainActor
final class PendingAgentSource: AgentSessionSource {
    let summary: AgentSessionSummary
    private let cache: AgentTranscriptCache?
    private let keptKey: String?
    private var onKept: (@MainActor (String) -> Void)?
    private var continuations: [AsyncStream<AgentSessionEvent>.Continuation] = []

    init(summary: AgentSessionSummary, cache: AgentTranscriptCache?, keptKey: String?, onKept: @escaping @MainActor (String) -> Void) {
        self.summary = summary
        self.cache = cache
        self.keptKey = keptKey
        self.onKept = onKept
        guard let cache, let keptKey else { return }
        Task { [weak self] in
            guard let entry = await cache.load(keptKey), let self, let onKept = self.onKept else { return }
            self.onKept = nil
            onKept(entry.sessionID)
        }
    }

    var loadsHistory: Bool { true }

    func events() -> AsyncStream<AgentSessionEvent> {
        let (stream, continuation) = AsyncStream<AgentSessionEvent>.makeStream()
        continuations.append(continuation)
        return stream
    }

    /// How long a prompt waits for the chat's real source before it comes back to the composer:
    /// `AcpmuxSessionSource.heldPromptWindow`, so a send while the chat loads rides out a blip
    /// the way a send on a loaded chat does (Leo, 2026-11-14: "i also want all our connectivity
    /// stuff to shut the fuck up and load faster").
    var holdWindow: Duration = AcpmuxSessionSource.defaultHeldPromptWindow {
        didSet {
            #if canImport(CmuxMobileLinkFFI)
            outbox.setHoldMs(holdMs: ChatPromptClock.milliseconds(holdWindow))
            #endif
        }
    }
    /// Each held prompt's intent, by its `promptId`.
    private var intents: [String: AgentClientIntent] = [:]

    #if canImport(CmuxMobileLinkFFI)
    /// The prompts sent before the chat loaded (Rust, `cmux_composer_send::chat`, its link never
    /// up): their order, their hold, and the ones given back past it.
    private let outbox = ChatPromptOutbox(holdMs: chatPromptDefaultHoldMs(), seed: 0)
    private var wake: Task<Void, Never>?

    /// Prompts sent before the chat loaded, oldest first, with when each was sent.
    var held: [(intent: AgentClientIntent, at: ContinuousClock.Instant)] {
        var held: [(intent: AgentClientIntent, at: ContinuousClock.Instant)] = []
        for id in outbox.unwritten() {
            guard let intent = intents[id] else { continue }
            held.append((intent: intent, at: tapped[id] ?? ContinuousClock.now))
        }
        return held
    }
    private var tapped: [String: ContinuousClock.Instant] = [:]
    #else
    private(set) var held: [(intent: AgentClientIntent, at: ContinuousClock.Instant)] = []
    #endif

    /// A prompt is held for the chat's real source (``takeHeld()``); anything else has nothing
    /// to act on yet and says why.
    func send(_ intent: AgentClientIntent) {
        hold(intent, since: ContinuousClock.now)
    }

    /// Holds `intent`, aged from `since` (a prompt handed over from an earlier loading source
    /// keeps its first send's time, so the hold is one window in all).
    func hold(_ intent: AgentClientIntent, since at: ContinuousClock.Instant) {
        guard case .prompt(let text, _, _, let promptID, let resend) = intent else {
            let reason = "Connecting to \(summary.macName)…"
            for continuation in continuations { continuation.yield(.clientError(reason)) }
            return
        }
        #if canImport(CmuxMobileLinkFFI)
        guard outbox.push(promptId: promptID, text: text, uploadIds: [], resend: resend,
                          tappedMs: ChatPromptClock.milliseconds(at),
                          nowMs: ChatPromptClock.milliseconds(at)) else { return }
        intents[promptID] = intent
        tapped[promptID] = at
        expireDue()
        #else
        _ = (text, promptID, resend)
        held.append((intent, at))
        #endif
    }

    /// The held prompts with their send times, for the chat's next source (the coordinator, as
    /// it builds it). They are no longer this source's to return.
    func takeHeld() -> [(intent: AgentClientIntent, at: ContinuousClock.Instant)] {
        #if canImport(CmuxMobileLinkFFI)
        var taken: [(intent: AgentClientIntent, at: ContinuousClock.Instant)] = []
        for prompt in outbox.drainUnwritten() {
            guard let intent = intents[prompt.promptId] else { continue }
            taken.append((intent: intent, at: tapped[prompt.promptId] ?? ChatPromptClock.instant(prompt.tappedMs)))
        }
        intents = [:]
        tapped = [:]
        wake?.cancel()
        return taken
        #else
        defer { held = [] }
        return held
        #endif
    }

    /// The prompt sent at `sentAt` waited out the window: it and every prompt after it come back
    /// to the composer (none goes after an earlier one that did not), as `AcpmuxSessionSource` does.
    func expire(sentAt: ContinuousClock.Instant) {
        #if canImport(CmuxMobileLinkFFI)
        guard let id = outbox.unwritten().first(where: { tapped[$0] == sentAt }) else { return }
        gaveBack(ids: outbox.giveUpFrom(promptId: id).map(\.promptId))
        #else
        guard let index = held.firstIndex(where: { $0.at == sentAt }) else { return }
        let dropped = held[index...]
        held.removeSubrange(index...)
        gaveBack(dropped.map(\.intent))
        #endif
    }

    #if canImport(CmuxMobileLinkFFI)
    /// Gives back what is past the hold now, and wakes for the next hold.
    private func expireDue() {
        let nowMs = ChatPromptClock.milliseconds(ContinuousClock.now)
        gaveBack(ids: outbox.expire(nowMs: nowMs).map(\.promptId))
        wake?.cancel()
        guard let wait = outbox.nextWakeMs(nowMs: nowMs) else { wake = nil; return }
        wake = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int64(clamping: wait)))
            guard !Task.isCancelled else { return }
            self?.expireDue()
        }
    }

    private func gaveBack(ids: [String]) {
        var dropped: [AgentClientIntent] = []
        for id in ids {
            tapped[id] = nil
            if let intent = intents.removeValue(forKey: id) { dropped.append(intent) }
        }
        gaveBack(dropped)
    }
    #endif

    private func gaveBack(_ dropped: [AgentClientIntent]) {
        // Short, with nothing to decode: the draft is back in the composer and Send is the action
        // (Leo 2026-11-23: the old copy was "way too long and unactionable").
        let reason = "Not sent: \(summary.macName) is offline."
        for intent in dropped {
            guard case .prompt(let text, let attachments, _, let promptID, _) = intent else { continue }
            for continuation in continuations {
                continuation.yield(.promptNotSent(text: text, attachments: attachments, promptID: promptID, reason: reason))
            }
        }
    }
}

/// An agent tab with no acpmux session yet: a new chat on the Mac that has
/// not had its first message. It shows as a new chat, and its first send starts
/// the chat from the phone, in this tab (``LiveWorkspaceCreationBackend/startUnboundChat``;
/// Leo, 2026-11-18: "you should be able to just start the chat right there");
/// once the tab is bound the coordinator rebuilds the store live on its session.
@MainActor
final class UnboundAgentSource: AgentSessionSource {
    /// Starts the tab's chat and sends it the first message (through the bound chat, which then shows);
    /// nil when the phone cannot (no link to the tab's Mac). Throws, with nothing sent, when the chat did not start.
    typealias Start = @MainActor (_ text: String, _ attachments: [AgentAttachment]) async throws -> Void

    let summary: AgentSessionSummary
    let macName: String
    private let start: Start?
    /// A start is running: a second send waits for it rather than starting another chat.
    private var starting = false

    init(summary: AgentSessionSummary, macName: String?, start: Start? = nil) {
        self.summary = summary
        self.macName = macName ?? summary.macName
        self.start = start
    }

    /// Why a send could not start the chat, with no link to the tab's Mac.
    static func notConnected(mac: String) -> String {
        "Connect to \(mac) to start this chat."
    }

    private var continuations: [AsyncStream<AgentSessionEvent>.Continuation] = []

    func events() -> AsyncStream<AgentSessionEvent> {
        let (stream, continuation) = AsyncStream<AgentSessionEvent>.makeStream()
        continuations.append(continuation)
        return stream
    }

    /// The first message starts the chat; a start that fails hands the draft back here with why
    /// (once bound, the chat on screen is the session's, which hands back a failed send itself).
    func send(_ intent: AgentClientIntent) {
        guard case .prompt(let text, let attachments, _, let promptID, _) = intent else { return }
        let notSent = { [weak self] (reason: String) in
            for continuation in self?.continuations ?? [] {
                continuation.yield(.promptNotSent(text: text, attachments: attachments, promptID: promptID, reason: reason))
            }
        }
        guard let start else { return notSent(Self.notConnected(mac: macName)) }
        guard !starting else { return notSent("\(summary.agentName) is still starting. Send again in a moment.") }
        starting = true
        for continuation in continuations { continuation.yield(.historyLoading(true)) }
        // task-owner: one start; the bound chat replaces this one on screen
        Task { [weak self] in
            do {
                try await start(text, attachments)
            } catch {
                notSent((error as? WorkspaceCreationError)?.message ?? String(describing: error))
                for continuation in self?.continuations ?? [] { continuation.yield(.historyLoading(false)) }
            }
            self?.starting = false
        }
    }

    var artifactSource: any ArtifactSource {
        LinkFileArtifactSource(macName: summary.macName, baseDirectory: summary.cwd) { nil }
    }
}
#endif
