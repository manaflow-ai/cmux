#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileArtifacts
import CmuxMobileBrowserStream
import CmuxMobileChief
import CmuxMobileDesign
import CmuxMobileFeed
import CmuxMobileModel
import CmuxMobileNotifications
import CmuxMobileTransport
import Foundation
import Observation
import OSLog

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
    public internal(set) var chiefStatus: String?
    /// Pairing with the linked Mac (verify/phone-approvals.md): the Mac asks the
    /// user the first time; Allow then signs with Face ID.
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
    /// The focused Mac's Feed source.
    public var feed: LiveFeed { focused.feed }
    /// The focused Mac's terminal agents' events in the Feed.
    public var terminalFeed: TerminalFeed { focused.terminalFeed }

    @ObservationIgnored let store: AppStore
    @ObservationIgnored let api: LiveAPI
    @ObservationIgnored let identity: DeviceIdentity
    /// Where `identity` and the pairing keys are kept (the Keychain; memory in tests).
    @ObservationIgnored let secrets: any DeviceSecretStore
    @ObservationIgnored let userID: String
    @ObservationIgnored let deviceName: String
    /// The phone's keys; nil (tests, mock) skips pairing.
    @ObservationIgnored let pairing: LinkPairing?
    @ObservationIgnored let clock: any Clock<Duration>
    @ObservationIgnored private var presence: PresenceListener?
    @ObservationIgnored private var isBackgrounded = false
    @ObservationIgnored private var teamTask: Task<Void, Never>?
    @ObservationIgnored var bannerTask: Task<Void, Never>?
    @ObservationIgnored var everConnected = false
    /// Macs a link was connected to: a failed redial to one says
    /// "Reconnecting", not "Can't reach" (the link keeps retrying).
    @ObservationIgnored var connectedMacIDs: Set<String> = []
    /// The acpmux session (and Mac) each cached chat store was built for (nil: unbound).
    @ObservationIgnored var sourcedSessions: [String: (tabID: String, macID: String, session: String?)] = [:]
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
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
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
    /// The team whose registration, Macs and presence are running or done.
    @ObservationIgnored private var startedTeamID: String?
    /// The team the Feed's items came from. Feed items carry no Mac, so on a switch they
    /// go (the new team's Macs fill it on connect): an old team's ask answered here went to
    /// the new team's Mac and failed, or reached the wrong one.
    @ObservationIgnored private var feedTeamID: String?
    @ObservationIgnored var feedSavePending = false
    /// The Feed's answers (`FeedStore.actions` is weak: this keeps them alive).
    @ObservationIgnored var feedActions: MultiMacFeedActions?
    /// How long a connected Mac may take to send its workspace list before
    /// the list says it could not load them (with Retry), instead of a
    /// skeleton that never ends.
    static let workspacesDeadline: Duration = .seconds(10)
    /// How often discovery looks while the active team has no online Mac, and otherwise.
    static let waitingPoll: Duration = .seconds(4)
    static let idlePoll: Duration = .seconds(30)

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
        clock: any Clock<Duration> = ContinuousClock()
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
        self.transport = transport
        self.relayOnly = relayOnly
        self.blockUDP = blockUDP
        self.dialer = dialer
        self.feedStore = feedStore
        let apiForLink = api
        idleSession = MacSession(
            macID: "", name: "", link: LinkController(transport: transport, dialer: dialer, clock: clock,
                                                     accessToken: { try await apiForLink.accessToken($0) }),
            deviceID: identity.link, deviceName: deviceName, feedStore: feedStore)
        // The default Chief is the account's Cloud Chief (same sign-in);
        // the Mac Chief below stays reachable beside it.
        ChiefSources.shared.start(userID: userID) { try await apiForLink.accessToken($0) }
        // The Feed as this phone last saw it; the Mac's history merges in on connect.
        let archive = FeedArchive.forAccount(userID)
        feedStore.useReadMarks(readMarks ?? .forAccount(userID))
        feedStore.replaceAll(archive.load())
        feedStore.onItemsChange = { [weak self] items in
            self?.scheduleFeedSave(archive)
            for session in self?.sessions.values ?? [:].values { session.terminalFeed.itemsChanged(items) }
        }
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
        AgentSessionDirectory.shared.makeSource = { [weak self] summary in
            guard let self else { return UnboundAgentSource(summary: summary, macName: nil) }
            // The tab's own Mac (tab ids repeat across Macs); a chat of a Mac
            // whose link is closed opens it, and is rebuilt once its tree lists the tab.
            let owner = self.session(tabID: summary.id, macID: summary.macID.isEmpty ? nil : summary.macID)
            if !summary.macID.isEmpty, owner?.link.target == nil { self.touch(summary.macID) }
            let session = owner?.tree?.agentTabs[summary.id]?.session
            self.sourcedSessions[AgentSessionDirectory.key(id: summary.id, macID: summary.macID)] =
                (tabID: summary.id, macID: summary.macID, session: session)
            guard let owner, let session else {
                return UnboundAgentSource(summary: summary, macName: owner?.name ?? self.link.target?.name)
            }
            var scoped = summary
            scoped.accountID = self.userID
            return owner.acpmux.source(sessionID: session, summary: scoped)
        }
        restoreSnapshot()
        watchNetwork()
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
            ConnectTimeline.shared.mark("network_lost")
        case .changed(let path):
            log.info("network changed: \(path, privacy: .public)")
            presence?.kick()
            guard let teamID = registeredTeamID else { return }
            // Every link roams in place (one signaling socket carries them all);
            // one controller asks the dialer, the others only redial a failed link.
            focused.link.networkChanged(baseURL: api.baseURL, teamID: teamID, deviceID: identity.link)
            for session in sessions.values where session !== focused {
                if case .waiting = session.link.phase { session.link.send(.foreground) }
            }
        }
    }

    // MARK: Warm start

    /// Launch with a snapshot: show the space, its Macs and their last-known
    /// workspaces (marked cached), warm the signaling socket, and dial the
    /// Mac this phone last reached, all before Stack's team list or the
    /// service's Mac list answers. Registration, Macs and presence start at
    /// once in the background and correct anything that changed.
    private func restoreSnapshot() {
        guard let snapshot = snapshots.load(accountID: userID) else { return }
        self.snapshot = snapshot
        store.teams = [Team(id: snapshot.teamID, name: snapshot.teamName, macs: snapshot.macs)]
        store.activeTeamID = snapshot.teamID
        var workspaces: [Workspace] = []
        for mac in snapshot.macs {
            guard let saved = snapshot.workspaces[mac.id] else { continue }
            workspaces += saved.workspaces
            store.handleMacData(.restored(count: saved.workspaces.count, savedAt: saved.savedAt), macID: mac.id)
        }
        store.workspaces = workspaces
        store.teamDataState = .loaded
        ConnectTimeline.shared.mark("snapshot_restored", detail: "\(workspaces.count) workspaces")
        // The link device was registered in this space when the snapshot was
        // saved (registration is an upsert and survives), so the socket and
        // the dial need not wait for it.
        registeredTeamID = snapshot.teamID
        idleSession.link.prewarm(baseURL: api.baseURL, teamID: snapshot.teamID, deviceID: identity.link)
        retarget()
        startedTeamID = snapshot.teamID
        feedTeamID = snapshot.teamID
        teamTask = Task { [weak self] in await self?.startTeam(snapshot.teamID, warm: true) }
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

    private var personal: AppStore.AccountTeam {
        AppStore.AccountTeam(id: Self.personalTeamID(userID: userID), name: "Personal")
    }

    /// Applies the account's teams (or the personal space) and starts the
    /// active one. The personal space stays listed next to Stack teams while
    /// one of the account's Macs is in it. Starts Mac discovery.
    public func applyAccountTeams(_ teams: [AppStore.AccountTeam], selectedID: String?) {
        var list = teams.isEmpty ? [personal] : teams
        let keepsPersonal = store.activeTeamID == personal.id || store.teams.contains(where: { $0.id == personal.id && !$0.macs.isEmpty })
        if !teams.isEmpty, keepsPersonal { list.append(personal) }
        // A team the phone already shows (picked, or followed to a Mac) stays active.
        let keep = list.contains { $0.id == store.activeTeamID } ? store.activeTeamID : selectedID
        store.applyLiveTeams(list, selectedID: keep)
        activeTeamChanged()
        for team in list { loadPrefs(team.id) }
        if discoveryTask == nil { startDiscovery() }
        steerToInvite()
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

    /// Call after `store.selectTeam`: re-registers, reloads Macs, re-targets
    /// the link. `byUser` marks a sidebar pick, which discovery respects.
    public func activeTeamChanged(byUser: Bool = false) {
        let teamID = store.activeTeamID
        if byUser { pinnedTeamID = teamID }
        guard !teamID.isEmpty, teamID != registeredTeamID, teamID != startedTeamID else { return }
        startedTeamID = teamID
        if let feedTeamID, feedTeamID != teamID { feedStore.replaceAll([]) }
        feedTeamID = teamID
        teamTask?.cancel()
        presence?.stop()
        presence = nil
        registeredTeamID = nil
        store.teamDataState = .loading
        closeAllSessions()
        teamTask = Task { [weak self] in await self?.startTeam(teamID) }
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
            // A warm start keeps its cached list; the retry below catches up.
            if !warm { store.teamDataState = .failed }
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
            presenceConnected = connected
        case .snapshot(let macs):
            applyMacs(macs, teamID: teamID, askedAt: removedMacs.mark)
        case .mac(let mac) where mac.removed == true:
            forgetMac(mac.deviceId)
        case .mac(let mac):
            var current = store.teams.first { $0.id == teamID }?.macs ?? []
            let known = current.first { $0.id == mac.deviceId }
            // A Worker that predates machine ids sends none: keep the one the list had. A
            // presence frame names no owner; the caller's hub carries only the caller's own
            // Macs (0.10.0), so a Mac new to the list is the caller's.
            let owner = othersMacs.contains(mac.deviceId) ? known?.ownerUserID : (known?.ownerUserID ?? userID)
            let device = MacDevice(id: mac.deviceId, name: mac.name, isOnline: mac.online, lastSeenAt: mac.lastSeenDate,
                                   ownerUserID: owner, machineID: mac.machineId ?? known?.machineID)
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
    @ObservationIgnored private var othersMacs: Set<String> = []

    /// A Mac its owner deleted (here or on another device): gone from every
    /// team with its cached workspaces and connection state. When the link
    /// was on it, the link moves to another Mac (or to none) at once, so
    /// nothing keeps saying "Connecting…" to a Mac that no longer exists.
    func forgetMac(_ id: String) {
        let linked = sessions[id]?.link.target != nil
        // Its link closes first, and its phase change must not write data for it back.
        closeSession(id)
        // Its banner, pairing prompt and Chief go with it (retarget may focus another Mac).
        if focusedMacID == id { setFocus(nil) }
        lastShown[id] = nil
        let known = store.forgetMac(id)
        othersMacs.remove(id)
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
        store.setMacs(macs.map { MacDevice(id: $0.deviceId, name: $0.name, isOnline: $0.online, lastSeenAt: $0.lastSeenDate,
                                           ownerUserID: $0.ownerUserId, machineID: $0.machineId) }, teamID: teamID)
        retarget()
        steerToInvite()
        scheduleSnapshotSave()
    }

    /// Focuses the selected Mac (remembered per team), else the first online
    /// one, and holds a link to each Mac `linkPolicy` keeps.
    func retarget() {
        guard let team = store.activeTeam, registeredTeamID == team.id else { return }
        let remembered = UserDefaults.standard.string(forKey: "cmuxMobile.live.mac.\(team.id)")
            ?? (snapshot?.teamID == team.id ? snapshot?.linkedMacID : nil)
        let next = LinkMachine.target(in: listedMacs(team), remembered: remembered, current: focusedMacID)
        // The focused Mac's session exists before the focus moves to it.
        if let next { _ = session(for: next) }
        setFocus(next?.id)
        applyLinks()
    }

    /// The Macs the phone focuses and the screens list: the owner's own, one
    /// build per computer (``MacRoster``).
    private func listedMacs(_ team: Team) -> [MacDevice] {
        MacRoster(team.macs.filter { !othersMacs.contains($0.id) }).visible
    }

    /// The Macs this phone may link: the listed ones, and another build on a
    /// listed Mac while something names it (a Feed answer or a notification of
    /// that build, `touch`, or a link it still holds until idle), so an ask
    /// from that build is still answered on it.
    /// A Mac whose pairing code is held is one too, while the code is.
    private func dialableMacs(_ team: Team) -> [MacDevice] {
        let own = team.macs.filter { !othersMacs.contains($0.id) }
        let listed = Set(MacRoster(own).visible.map(\.id))
        let invited = pairing?.invites.pending()?.mac
        return own.filter { listed.contains($0.id) || lastShown[$0.id] != nil || $0.id == invited }
    }

    /// The focused Mac changed: the last one stays linked while it is recent
    /// (`MacLinkPolicy.idleAfter`), and the banner, pairing and Chief follow.
    private func setFocus(_ macID: String?) {
        guard macID != focusedMacID else { return }
        if let old = focusedMacID { lastShown[old] = ContinuousClock.now }
        focusedMacID = macID
        if let macID { lastShown[macID] = ContinuousClock.now }
        pairingState = focused.pairingState
        chiefFollowsFocus()
        phaseChanged(focused)
    }

    /// Opens a link to every Mac the policy keeps and closes the others.
    func applyLinks(_ dialable: [MacDevice]? = nil) {
        guard let team = store.activeTeam, registeredTeamID == team.id else { return }
        let macs = dialable ?? dialableMacs(team)
        let now = ContinuousClock.now
        // nil (Workspaces, the Feed): every listed Mac. Another build of a listed Mac is
        // never "shown" by that: it keeps its link only for the idle window after
        // something named it (`touch`), then closes.
        let showing = showingMacs ?? Set(listedMacs(team).map(\.id))
        for id in showing { lastShown[id] = now }
        // A live link that presence briefly calls offline (a signaling reset) ranks as online:
        // the cap never closes it for that.
        let ranked = macs.map { mac -> MacDevice in
            guard !mac.isOnline, sessions[mac.id]?.link.phase.isConnected == true else { return mac }
            var live = mac
            live.isOnline = true
            return live
        }
        let decision = linkPolicy.decide(macs: ranked, focused: focusedMacID, showing: showing, lastShown: lastShown, now: now,
                                         pinned: pairing?.invites.pending()?.mac)
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
        let now = ContinuousClock.now
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
        wire(session)
        sessions[mac.id] = session
        return session
    }

    /// Closes a Mac's link and forgets its session.
    private func closeSession(_ id: String) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        for relay in session.cloudChats.values { relay.retire() }
        session.cloudChats.removeAll()
        session.link.send(.target(nil))
        // Its data on screen is last-known now, and nothing says it is connected.
        if session.fedData { store.handleMacData(.disconnected(at: Date()), macID: id) }
        store.macConnection[id] = nil
        if store.macLinkStatus[id] != nil { store.macLinkStatus[id] = nil }
        store.macLinkDiagnostics[id] = nil
        session.offlineTask?.cancel()
        session.workspacesTimeout?.cancel()
        session.acpmux.cancelWaiters()
        Task {
            await session.workspaces.bind(nil, macID: "")
            await session.acpmux.bind(nil)
        }
    }

    /// Closes every link (another team, sign-out).
    private func closeAllSessions() {
        for id in Array(sessions.keys) { closeSession(id) }
        focusedMacID = nil
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

    private func startDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in await self?.discover() }
    }

    private func discover() async {
        while !Task.isCancelled {
            await discoverOnce()
            let waiting = !(store.activeTeam?.macs.contains(where: \.isOnline) ?? false)
            do { try await clock.sleep(for: waiting ? Self.waitingPoll : Self.idlePoll) } catch { return }
        }
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
                                 ownerUserID: mac.ownerUserId ?? userID, machineID: mac.machineId)
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
    /// approval key (Face ID); nil without pairing keys or a paired Mac.
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
        stopped = true
        ChiefSources.shared.stop()
        networkTask?.cancel()
        networkTask = nil
        discoveryTask?.cancel()
        discoveryTask = nil
        teamTask?.cancel()
        presence?.stop()
        presence = nil
        registeredTeamID = nil
        startedTeamID = nil
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
        for session in sessions.values { session.link.send(.relayOnly(relayOnly)) }
    }

    /// Debug UDP-blocked mode (Settings → Developer); a change redials.
    public func setBlockUDP(_ blockUDP: Bool) {
        self.blockUDP = blockUDP
        for session in sessions.values { session.link.send(.blockUDP(blockUDP)) }
    }

    /// Keep background work usable, but do not trust these links after suspension.
    public func background() {
        isBackgrounded = true
        for session in sessions.values { session.link.send(.background) }
    }

    /// App foreground: immediately replace stale links and refresh presence.
    public func foreground() {
        isBackgrounded = false
        log.info("foreground: \(String(describing: self.link.phase), privacy: .public)")
        // The first activation is the launch itself, already being measured.
        if ConnectTimeline.shared.sinceProcessStart > 5 { ConnectTimeline.shared.begin("foreground") }
        if let teamID = registeredTeamID {
            idleSession.link.prewarm(baseURL: api.baseURL, teamID: teamID, deviceID: identity.link)
        }
        presence?.kick()
        if discoveryTask != nil { startDiscovery() }
        for session in sessions.values { session.link.send(.resume) }
    }

}

/// An agent tab with no acpmux session yet: a new chat on the Mac that has
/// not had its first message. The Mac starts a chat's session from its own
/// first send (the daemon starts only `registry:` tabs), so the phone says so;
/// once the Mac binds the session the coordinator rebuilds the store live.
@MainActor
final class UnboundAgentSource: AgentSessionSource {
    let summary: AgentSessionSummary
    let macName: String

    init(summary: AgentSessionSummary, macName: String?) {
        self.summary = summary
        self.macName = macName ?? summary.macName
    }

    static func notStarted(agent: String, mac: String) -> String {
        "\(agent) hasn't started in this tab. Send the first message from cmux on \(mac); the chat continues here."
    }

    private var continuations: [AsyncStream<AgentSessionEvent>.Continuation] = []

    func events() -> AsyncStream<AgentSessionEvent> {
        let (stream, continuation) = AsyncStream<AgentSessionEvent>.makeStream()
        continuation.yield(.clientError(Self.notStarted(agent: summary.agentName, mac: macName)))
        continuations.append(continuation)
        return stream
    }

    /// A prompt can't start the chat from the phone: say why again.
    func send(_ intent: AgentClientIntent) {
        let message = Self.notStarted(agent: summary.agentName, mac: macName)
        for continuation in continuations { continuation.yield(.clientError(message)) }
    }

    var artifactSource: any ArtifactSource {
        LinkFileArtifactSource(macName: summary.macName, baseDirectory: summary.cwd) { nil }
    }
}
#endif
