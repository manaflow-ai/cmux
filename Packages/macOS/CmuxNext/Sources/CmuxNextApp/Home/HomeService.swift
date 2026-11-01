import CmuxHomeCore
import CmuxNextActions
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextHome
import CmuxNextHomeEngine
import CmuxNextHostedChief
import CmuxNextWakeups
import Foundation
import Observation
import os

/// Home's client of the Chief home's conversation owner
/// (`ChiefConversationOwner`, plans/cmux-next/home-state-ownership.md): the
/// conversation list, one session (mirror + intent log) per open
/// conversation, and the typed ops the user sends. The owner is this build's
/// Chief home's daemon session (`ChiefHome`); nothing here is persisted.
/// The build's own daemon keeps only the Home workspace and its tabs.
@Observable @MainActor
final class HomeService {
    /// Conversations, newest activity first, as the owner reports them.
    private(set) var conversations: [CmuxNextDaemon.ConversationSummary] = []
    /// Set while older builds' Chiefs block the move into the Chief home.
    var migrationNotice: String?
    /// The Chief conversation whose settings open once its Home view shows it: Toggle Chief
    /// Settings with no Home in front brings Home forward there (`HomeChiefActions`).
    @ObservationIgnored var pendingChiefSettings: ConversationID?
    #if DEBUG || CMUX_BENCH_HOOKS
    /// DEBUG: the Chiefs of `debug.home.sidebar_fixture`'s rows, which wear their own characters too.
    var debugChiefs: Set<String> = []
    #endif
    /// While a Chief turn waits for the compactor (ChiefSettleWatch).
    var settleNotice: String?
    @ObservationIgnored var settleWatch: ChiefSettleWatch?
    /// While the person's last message to this Mac's Chief has had no reply for two minutes
    /// (ChiefReplyWatchdog).
    var replyNotice: String?
    @ObservationIgnored private var replyWatch: Task<Void, Never>?
    @ObservationIgnored private let replyTimer = DemandTimer(owner: "HomeService.replyWatchdog")
    /// Chief's first-launch welcome (ChiefWelcome), played once for the app's life.
    @ObservationIgnored let chiefWelcome = ChiefWelcomePlayer()
    /// The Chief home's conversation owner serves `local-conversations-v1`.
    var isAvailable: Bool { chief.supports(DaemonCapability.localConversations.rawValue) }
    /// The owner answered and its build is too old: Home shows why only then.
    var isRefused: Bool { chief.refusal != nil }
    /// The owner of every Home conversation: this build's Chief home's (one Chief per build).
    @ObservationIgnored let chief: ChiefConversationOwner
    /// Keeps the Chief home's brain host running (ChiefBrainKeeper).
    @ObservationIgnored lazy var brain = ChiefBrainKeeper(
        home: chief.home, connection: { [weak self] in self?.connection },
        resolveHost: { [weak self] connection in
            guard let self, let socket = await connection.endpoint?.socketPath else { return nil }
            var host = HomeBrainHost.resolve(daemonSocket: socket, controlSocket: services.environment.launch.socketPath, home: chief.home,
                                             appBuild: services.environment.build)
            // A Chief on the app's own acpmux waits for it: the local pane host starts it.
            let local = services.agentTabs.host
            host?.ensureAppAcpmux = { try? await local.prewarm() }
            return host
        },
        mint: { connection in try await ConversationClient(connection).agentToken(for: HomeService.mux.id) },
        // The default Chief is this Mac's while its brain runs, so a brain that
        // just started or died re-runs the Chief tab check (HomeService+ChiefRoster).
        hostChanged: { [weak self] _ in self?.localChiefHostChanged() })
    @ObservationIgnored private(set) var sessions: [String: HomeConversationSession] = [:]
    @ObservationIgnored unowned let services: AppServices
    @ObservationIgnored private var availability: Task<Void, Never>?
    @ObservationIgnored private var listing: Task<Void, Never>?
    /// Home opened in a window this launch; the host starts once the Chief
    /// owner is connected, even when Home opened first.
    @ObservationIgnored private var homeWasOpened = false
    /// Whether Home opened this launch (for the app links).
    var homeOpened: Bool { homeWasOpened }
    /// The tagged daemon socket this app last published (ChiefAppLinks).
    @ObservationIgnored var publishedDaemonSocket: String?
    @ObservationIgnored var activationObserver: (any NSObjectProtocol)?
    /// The store's home workspace (`workspace-kind-v1`), from `workspace.ensure_home`.
    var homeWorkspaceID: ResourceID?
    /// An `ensure_home` is in flight. A tree snapshot taken meanwhile can
    /// show the new home workspace before its kind row, so launch waits for
    /// the answer before it decides on a first workspace (`needsFirstWorkspace`).
    var homeEnsureInFlight = false
    /// The latest `ensure_home`; only it clears `homeEnsureInFlight`.
    @ObservationIgnored var homeEnsureGeneration = 0
    @ObservationIgnored var homeWorkspaceTask: Task<Void, Never>?
    /// The last step the home workspace setup reached, for `debug.home`.
    @ObservationIgnored var homeWorkspaceStep = "not started"
    /// The chief tab creation's idempotency key (one per creation).
    @ObservationIgnored let chiefTabKey = HomeChiefTabKey()
    @ObservationIgnored let dock = HomeDock() // the Home dock's page tab and links (cx-ebm.59.5, cx-ebm.59.6)
    /// The signed-in user's cloud Chiefs (the Hosted Chief and the one
    /// placed on a paired server), as last read on a connect or sign-in.
    private(set) var cloudChiefs = HomeCloudChiefs()
    /// Chief renames being saved, shown at once on every surface (``chiefName(of:)``).
    var chiefRenames = HomeChiefNames()
    #if DEBUG || CMUX_BENCH_HOOKS
    /// Every live Home view, for `debug.home.api` `chief_names` (each one's header name).
    @ObservationIgnored let debugHostViews = NSHashTable<HomeHostView>.weakObjects()
    #endif
    /// The cloud Chief whose main conversation is the Chief tab, or nil (the local Chief, also
    /// whenever it is the default Chief: ``prefersLocalChief``).
    var cloudChief: CloudChief? { prefersLocalChief ? nil : tabChiefs.shown(choice: hostedChief.choice) }
    /// This Mac's optchat-chief held the Chief home's lock at the last Chief tab check (HomeService+ChiefDefault).
    var localChiefRunning = false
    /// How many reads of that lock have started, and the newest one that published its answer, so
    /// an older read never lands on top of a newer one (``readLocalChiefRunning``).
    @ObservationIgnored var chiefRunningReads = 0
    @ObservationIgnored var chiefRunningPublished = 0
    /// The cloud Chiefs the Chief tab may show: without the Hosted Chief while
    /// this Mac's history is still being copied into it (the local Chief stays).
    var tabChiefs: HomeCloudChiefs { hostedChief.pending ? HomeCloudChiefs(hosted: nil, placed: cloudChiefs.placed) : cloudChiefs }
    /// The one-time copy of this Mac's Chief into the Hosted Chief and its brain check (HomeService+HostedChief).
    @ObservationIgnored let hostedChief = HostedChiefMigration()
    @ObservationIgnored private var homeObservation: Task<Void, Never>?
    /// Re-runs the Chief tab check when Settings > Chief's Engine changes (HomeService+ChiefDefault).
    @ObservationIgnored var chiefEngineObservation: Task<Void, Never>?
    /// Shows the Feed's notices in the default Chief's transcript (HomeService+FeedRows).
    @ObservationIgnored var feedRowsObservation: Task<Void, Never>?
    /// The latest brain start or death's tab check (HomeService+ChiefRoster); a newer one wins.
    @ObservationIgnored var chiefHostChange: Task<Void, Never>?
    /// The shared Home core over the local owner (home-mac.md): the native
    /// transcript of every conversation tab reads this one store.
    /// Mermaid fences in Home chat draw as diagrams with the bundled Ondine
    /// (`markdown-viewer/ondine.min.js`); one renderer (one JavaScriptCore context) for every pane.
    /// nil when the bundle lacks the script: fences stay text.
    @ObservationIgnored private(set) lazy var diagrams: OndineMermaidRenderer? = OndineMermaidRenderer.bundled()
    @ObservationIgnored let homeSource = DaemonHomeSource(me: HomeCoreMapping.participant(HomeService.localUser))
    /// Cloud conversations through the daemon's proxy (home-cloud-proxy.md),
    /// merged with the local ones into the one store.
    @ObservationIgnored let cloudSource = CloudHomeSource(me: HomeCoreMapping.participant(HomeService.localUser))
    /// Message requests from people the user is not connected to (home-messaging-invites DESIGN 2.3).
    @ObservationIgnored private(set) lazy var requests = HomeMessageRequests(source: cloudSource)
    @ObservationIgnored private(set) lazy var homeRouter = HomeSourceRouter(local: homeSource, cloud: cloudSource)
    /// The Home list rows (`home-inbox`) the Messages list maps: local from the Chief home, Cloud from the build daemon.
    @ObservationIgnored let homeInbox = HomeInboxSource(owners: ["local"])
    @ObservationIgnored let homeCloudInbox = HomeInboxSource(owners: ["cloud"])
    /// The Home list's last state beyond the conversations, for the next launch's first frame
    /// (HomeService+LaunchList), kept beside the conversations' cache of the same Chief owner.
    @ObservationIgnored private(set) lazy var sidebarLaunch = HomeSidebarLaunchCache.standard(owner: chief.home.session,
                                                                                               caches: homeCaches)
    /// The folder of this service's Home caches: the app's (`AppEnvironment.homeCachesDirectory`), else
    /// a temporary folder of its own, so the drafts of one `AppServices` never reach another's.
    @ObservationIgnored private lazy var homeCaches: URL = services.environment.homeCachesDirectory
        ?? FileManager.default.temporaryDirectory.appending(path: "cmux-home-\(UUID().uuidString)", directoryHint: .isDirectory)
    /// The last launch's Chief roster, used until the cloud Chiefs are read (`chiefRoster`).
    @ObservationIgnored var launchRoster: HomeChiefRoster?
    /// The cloud Chiefs were read this launch (`setCloudChiefs`). Observed: the roster changes with it.
    var cloudChiefsRead = false
    @ObservationIgnored var homeListPrimed = false
    @ObservationIgnored var launchListObservation: Task<Void, Never>?
    /// This Mac's old Messages-list pins, moved into those owners once (cx-frn2y).
    @ObservationIgnored private(set) lazy var pinMigration = HomePinMigration(account: { [weak self] in self?.pinAccount ?? "local" })
    /// The docked Home's shown view: the sidebar marks its Home or Channels entry by it (cx-frn2y).
    var dockMode: HomeDockMode = .messages
    var dockShowsChannels: Bool { dockMode == .channels }
    /// Its durable copy is keyed by the Chief owner (one per Chief home), so
    /// a relaunch or another build shows the same history before the owner
    /// answers (home-state-ownership.md section 4).
    @ObservationIgnored private(set) lazy var homeStore = HomeStore(
        source: homeRouter,
        blobCacheDirectory: homeCaches.appending(path: "cmux-home-blobs", directoryHint: .isDirectory),
        cache: HomeCache.standard(owner: chief.home.session, caches: homeCaches))
    @ObservationIgnored var cloudLink: Task<Void, Never>?
    /// Team members and Chiefs for the Home page's New Message and New Chief.
    @ObservationIgnored private(set) lazy var directory = HomeDirectory(
        call: { [weak self] path, body in
            guard let feed = self?.services.feed else { throw FeedServiceError.signedOut }
            return try await feed.call(path, body)
        },
        teamCall: { [weak self] path, body, team in
            guard let feed = self?.services.feed else { throw FeedServiceError.signedOut }
            return try await feed.call(path, body, team: team)
        },
        activeTeam: { [weak self] in self?.activeWorkerTeam },
        me: { [weak self] in
            guard let auth = self?.services.cloud.auth, let id = auth.user?.id else { return nil }
            return CloudIdentity.workerUserID(stackProjectID: auth.configuration.stackProjectID, stackUserID: id)
        })
    /// The active team (`ActiveTeam`, Switch Active Team) as the Worker names it: Home lists its people only.
    var activeWorkerTeam: String? {
        let auth = services.cloud.auth
        guard auth.isSignedIn, let team = auth.activeTeam.id else { return nil }
        return CloudIdentity.workerTeamID(stackProjectID: auth.configuration.stackProjectID, stackTeamID: team)
    }
    /// Hide Alerts for the group actions (`groupActions`): a sidebar source over the same owners
    /// as every Home list, so a mute from the palette or the CLI reaches the row's owner.
    @ObservationIgnored private(set) lazy var groupMuting = makeSidebarSource()
    /// A conversation the Home page selects once the inbox lists it (a new
    /// Chief's main conversation, a DM opened from the CLI).
    var pendingSelection: ConversationID?
    /// Each chat's own bubble colours (Chat Colors…, `home.chatColors`), kept on this Mac.
    @ObservationIgnored let chatColors = HomeChatColorStore(defaults: .standard)
    /// The Chat Colors… panel (one for the app).
    @ObservationIgnored private(set) lazy var chatColorsPanel = HomeChatColorsPanel(store: chatColors, design: .shared)
    @ObservationIgnored var cloudLinker: HomeCloudLink?
    /// Each conversation tab's view, by tab id; released with the tab.
    @ObservationIgnored var tabViews: [String: HomeHostView] = [:]
    @ObservationIgnored let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")
    /// The local user's participant id in local conversations.
    let actor = ConversationParticipant.localUserID

    init(services: AppServices, chiefHome: ChiefHome? = nil) {
        self.services = services
        chief = ChiefConversationOwner(home: chiefHome ?? ChiefHome.resolve(tag: services.environment.tag))
        // MessagesLab's flight recorder (HomeTunables): DEV on, NIGHTLY opt-in, Release and RC never.
        HomeFlightRecording.install(available: DevTools.isEnabled,
                                    logFolder: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "cmux")
        wireHostedChief()
    }

    /// Observes the Chief owner: each new connection reloads the list and
    /// every open session, then resends what is still sending (same keys;
    /// the owner applies each once). The local daemon gets the Home workspace.
    func start() {
        // Local conversations come from the Chief owner; the build's own
        // daemon carries only the cloud proxy's events (its own conversation
        // store is the old per-tag one, which Home no longer shows).
        chief.onEvent = { [weak self] event in self?.handle(event) }
        services.machines.local.store.sideEvents.subscribe { [weak self] event in
            if case .cloudConversations = event { self?.handle(event) }
        }
        installChiefMigration()
        primeHomeList()
        pinMigration.attach([homeInbox, homeCloudInbox])
        settleWatch = ChiefSettleWatch(home: chief.home) { [weak self] text in
            if self?.settleNotice != text { self?.settleNotice = text }
        }
        watchReplies()
        chief.start()
        let local = services.machines.local
        let auth = services.cloud.auth
        let chief = chief
        // task-owner: lives as long as the service; event-driven (Observation)
        homeObservation = Task { [weak self] in
            // A sign-in or account change re-reads the placed chief (G6), so the Chief tab follows it.
            for await (connection, _) in ObservationStream({
                (local.supports(DaemonCapability.workspaceKind.rawValue) ? local.connection : nil, auth.isSignedIn ? auth.user?.id : nil)
            }) {
                guard let self, let connection else { continue }
                ensureHomeWorkspace(connection)
                // The Chief's daemon link names this connection's socket, known only once it is up.
                if homeWasOpened { publishAppLinks() }
            }
        }
        observeChiefEngine()
        observeFeedRows()
        // The active team behind the list's teammate rows and New Message's To:, read again once
        // the launch restore signs in, on another account, on another active team, and when the
        // account's teams change.
        directory.follow { [weak auth] in
            guard let auth, auth.isSignedIn, let user = auth.user?.id else { return nil }
            return user + "|" + (auth.activeTeam.id ?? "") + "|" + auth.activeTeam.teams.map(\.id).sorted().joined(separator: ",")
        }
        startCloud()
        // task-owner: lives as long as the service; event-driven (Observation)
        homeStore.start()
        keepHomeListForLaunch()
        availability = Task { [weak self] in
            for await connection in ObservationStream({ chief.supports(DaemonCapability.localConversations.rawValue) ? chief.connection : nil }) {
                guard let self else { continue }
                homeSource.connectionChanged(connection)
                homeInbox.connectionChanged(connection)
                guard let connection else { continue }
                reloadList(connection)
                // Home opened before the owner answered, or the owner came back
                // after a stop: start the host now if it does not run.
                if homeWasOpened { homeDidOpen(asked: false) }
                // The Chief tab may wait on this owner (a local Chief with history
                // takes it back from a placed chief): check it again now.
                if let local = services.machines.local.connection,
                   services.machines.local.supports(DaemonCapability.workspaceKind.rawValue) {
                    ensureHomeWorkspace(local)
                }
                for session in sessions.values {
                    session.load(from: connection) { [weak self, weak session] in
                        guard let self, let session else { return }
                        for send in session.log.resendable { submit(send, in: session) }
                    }
                }
            }
        }
    }

    /// The Chief owner's connection, while it serves conversations.
    var connection: DaemonConnection? { isAvailable ? chief.connection : nil }

    /// Records the cloud Chiefs the last read found (HomeService+Workspace).
    func setCloudChiefs(_ chiefs: HomeCloudChiefs) {
        if !cloudChiefsRead { cloudChiefsRead = true }
        if cloudChiefs != chiefs { cloudChiefs = chiefs }
    }

    /// Home opened in a window (or its owner reconnected, not `asked`): start
    /// the Chief home's brain host when none runs (ChiefBrainKeeper).
    func homeDidOpen(asked: Bool) {
        if !homeWasOpened {
            homeWasOpened = true
            publishAppLinks()
            observeActivation()
        }
        brain.ensure(asked: asked)
    }

    /// The open session for `conversation`, loaded on first use.
    func session(_ conversation: String) -> HomeConversationSession {
        if let session = sessions[conversation] { return session }
        let session = HomeConversationSession(id: conversation)
        sessions[conversation] = session
        if let connection { session.load(from: connection) }
        return session
    }

    func reloadList(_ connection: DaemonConnection) {
        listing?.cancel()
        // task-owner: one conversation-list read; ends with its reply
        listing = Task { [weak self] in
            do {
                let list = try await ConversationClient(connection).list()
                guard let self, !Task.isCancelled else { return }
                // Keep any head an event already moved past the listed revision.
                let current = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
                conversations = list.map { listed in
                    guard let known = current[listed.id], known.rev > listed.rev else { return listed }
                    return known
                }
                openChiefDirectMessages()
            } catch {
                self?.logger.error("conversation-list: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Events

    private func handle(_ event: DaemonEvent) {
        homeInbox.note(event)
        homeCloudInbox.note(event)
        switch event {
        case .conversationChanged(let changed):
            if case .message(let message) = changed.change { brain.ask(after: message, in: conversations.first { $0.id == changed.conversation }) }
            updateList(changed)
            homeSource.publish(changed, summary: conversations.first { $0.id == changed.conversation })
            guard let session = sessions[changed.conversation] else { return }
            if !session.apply(changed), let connection { session.load(from: connection) }
        case .conversationTyping(let typing):
            sessions[typing.conversation]?.setTyping(typing.participant, on: typing.on)
            homeSource.publish(.typing(ConversationID(typing.conversation), ParticipantID(typing.participant), on: typing.on))
        case .conversationDraft(let draft):
            homeSource.publish(.draft(HomeDraftUpdate(
                conversation: ConversationID(draft.conversation), participant: ParticipantID(draft.participant),
                turn: IdempotencyKey(draft.item.turn), segment: draft.item.segment, seq: draft.item.seq,
                isTalk: draft.item.kind == "talk", text: draft.item.text, fresh: draft.item.fresh, done: draft.item.done)))
        case .conversationLive(let live):
            homeSource.publish(live)
        case .conversationRunChanged(let changed):
            homeSource.publish(changed)
        case .cloudConversations(let event):
            handleCloud(event)
        case .unknown(name: "chief-changed", let payload) where payload["change"]?.stringValue == "created":
            // A Chief made by a Chief's chiefs tool or `cmux chief new` has no conversation yet:
            // the list read again opens its direct message (openChiefDirectMessages).
            if let connection { reloadList(connection) }
        default:
            break
        }
    }

    /// Keeps the list's heads current without a refetch; an unknown
    /// conversation (created elsewhere) refetches the list.
    private func updateList(_ event: ConversationEvent) {
        guard let index = conversations.firstIndex(where: { $0.id == event.conversation }) else {
            if let connection { reloadList(connection) }
            return
        }
        var summary = conversations[index]
        guard event.rev > summary.rev else { return }
        if event.rev > summary.rev + 1, let connection { reloadList(connection) }
        summary.rev = event.rev
        switch event.change {
        case .message(let message):
            summary.lastSeq = max(summary.lastSeq, message.seq)
            summary.lastMessage = message
            summary.updatedAt = message.createdAt
        case .messageUpdated(let message):
            if summary.lastMessage?.id == message.id { summary.lastMessage = message }
        case .readCursor(let participant, let seq):
            summary.readCursors[participant] = max(summary.readCursors[participant] ?? 0, seq)
        case .conversation(let head):
            summary = head
        case .unknown:
            break
        }
        conversations.remove(at: index)
        let insertion = conversations.firstIndex(where: { $0.updatedAt <= summary.updatedAt }) ?? conversations.endIndex
        conversations.insert(summary, at: insertion)
    }

    // MARK: Intents (user origin)

    /// Sends `text` as the local user. The bubble shows at once from the
    /// intent log and settles in place when the owner confirms it.
    func send(_ text: String, in conversation: String, replyTo: ConversationPartRef? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let session = session(conversation)
        let send = PendingConversationSend(clientMsgID: "c_" + UUID().uuidString.lowercased(), conversation: conversation,
                                           parts: [.text(trimmed, runs: HomeMentions.runs(in: trimmed, participants: participants(of: conversation)))],
                                           replyTo: replyTo, createdAt: Date())
        session.addPending(send)
        submit(send, in: session)
    }

    func retry(_ clientMsgID: String, in conversation: String) {
        guard let session = sessions[conversation], let send = session.retry(clientMsgID) else { return }
        submit(send, in: session)
    }

    /// Marks everything up to `seq` read for the local user (monotonic; the owner ignores regressions by rejecting them).
    func markRead(_ seq: UInt64, in conversation: String) {
        guard let connection, let head = conversations.first(where: { $0.id == conversation }),
              seq > (head.readCursors[actor] ?? 0) else { return }
        let request = ConversationOpRequest(conversation: conversation, idempotencyKey: "read:\(actor):\(seq)",
                                            transaction: nil, op: .setReadCursor(seq: seq))
        // task-owner: one conversation-op write; ends with its reply
        Task { [weak self] in
            do { _ = try await ConversationClient(connection).op(request) } catch {
                self?.logger.error("read_cursor.set: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func participants(of conversation: String) -> [ConversationParticipant] {
        conversations.first(where: { $0.id == conversation })?.participants ?? []
    }

    /// Sends one queued send. A command error is the owner's reject; a lost
    /// connection keeps it sending, and the next connection resends it.
    private func submit(_ send: PendingConversationSend, in session: HomeConversationSession) {
        guard let connection else { return }
        let request = ConversationOpRequest(conversation: send.conversation, idempotencyKey: send.clientMsgID,
                                            transaction: ClientTransactionID(rawValue: send.clientMsgID), op: send.op)
        // task-owner: one conversation-op write; ends with its reply
        Task { [weak self, weak session] in
            do {
                let result = try await ConversationClient(connection).op(request)
                session?.acknowledge(send.clientMsgID, result: result)
            } catch DaemonError.command(_, let message, let code, _, _) where code == "conversation_rejected" {
                session?.reject(send.clientMsgID, reason: message)
            } catch {
                self?.logger.info("conversation-op deferred to the next connection: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

// MARK: Reply watchdog

extension HomeService {
    /// Follows the local Chief conversation's head: when the person's last message has had no
    /// reply for `ChiefReplyWatchdog.limit`, the notice row says so, and it counts the minutes
    /// until a reply lands. One timer at a time, armed for the next change; no polling.
    fileprivate func watchReplies() {
        // task-owner: lives as long as the service; event-driven (Observation)
        replyWatch = Task { [weak self] in
            for await head in ObservationStream({ [weak self] in self.flatMap { HomeChiefName.select(from: $0.conversations) } }) {
                guard let self else { return }
                armReplyTimer(head)
            }
        }
    }

    private func armReplyTimer(_ head: CmuxNextDaemon.ConversationSummary?) {
        replyTimer.cancel()
        let now = Date()
        let notice = head.flatMap { ChiefReplyWatchdog.notice($0, now: now) }
        if replyNotice != notice { replyNotice = notice }
        guard let head, let next = ChiefReplyWatchdog.nextCheck(head, now: now) else { return }
        // One deadline: when the notice appears or its minute count changes; the next head resets it.
        replyTimer.schedule(after: .seconds(max(1, next.timeIntervalSinceNow))) { @MainActor [weak self] in
            guard let self else { return }
            armReplyTimer(HomeChiefName.select(from: conversations))
        }
    }
}
