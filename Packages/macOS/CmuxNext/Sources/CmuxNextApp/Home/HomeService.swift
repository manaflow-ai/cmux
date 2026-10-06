import CmuxHomeCore
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextHome
import Foundation
import Observation
import os

/// Home's client of the local conversation owner (plans/cmux-next/home.md):
/// the conversation list, one session (mirror + intent log) per open
/// conversation, and the typed ops the user sends. The owner is the daemon;
/// nothing here is persisted.
@Observable @MainActor
final class HomeService {
    /// Conversations, newest activity first, as the owner reports them.
    private(set) var conversations: [CmuxNextDaemon.ConversationSummary] = []
    /// The local daemon serves `local-conversations-v1`.
    var isAvailable: Bool { services.machines.local.supports(DaemonCapabilities.shared.localConversations) }
    @ObservationIgnored private(set) var sessions: [String: HomeConversationSession] = [:]
    @ObservationIgnored unowned let services: AppServices
    @ObservationIgnored private var availability: Task<Void, Never>?
    @ObservationIgnored private var listing: Task<Void, Never>?
    /// The brain host was started on this app launch (it outlives the app).
    @ObservationIgnored private var startedBrainHost = false
    /// The store's home workspace (`workspace-kind-v1`), from `workspace.ensure_home`.
    var homeWorkspaceID: ResourceID?
    @ObservationIgnored var homeWorkspaceTask: Task<Void, Never>?
    /// The last step the home workspace setup reached, for `debug.home`.
    @ObservationIgnored var homeWorkspaceStep = "not started"
    /// The chief tab creation's idempotency key (one per creation).
    @ObservationIgnored let chiefTabKey = HomeChiefTabKey()
    /// The signed-in user's chief placed on a paired server (G6), as last
    /// read on a connect or sign-in; its main conversation is the Chief tab.
    private(set) var cloudChief: CloudChief?
    @ObservationIgnored private var homeObservation: Task<Void, Never>?
    /// The shared Home core over the local owner (home-mac.md): the native
    /// transcript of every conversation tab reads this one store.
    @ObservationIgnored let homeSource = DaemonHomeSource(me: HomeCoreMapping.participant(HomeService.localUser))
    /// Cloud conversations through the daemon's proxy (home-cloud-proxy.md),
    /// merged with the local ones into the one store.
    @ObservationIgnored let cloudSource = CloudHomeSource(me: HomeCoreMapping.participant(HomeService.localUser))
    @ObservationIgnored private(set) lazy var homeRouter = HomeSourceRouter(local: homeSource, cloud: cloudSource)
    @ObservationIgnored private(set) lazy var homeStore = HomeStore(source: homeRouter)
    @ObservationIgnored var cloudLink: Task<Void, Never>?
    @ObservationIgnored var cloudLinker: HomeCloudLink?
    /// Each conversation tab's view, by tab id; released with the tab.
    @ObservationIgnored var tabViews: [String: HomeHostView] = [:]
    @ObservationIgnored let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")
    /// The local user's participant id in local conversations.
    let actor = ConversationParticipant.localUserID

    init(services: AppServices) {
        self.services = services
        // MessagesLab's flight recorder (HomeTunables): DEV on, NIGHTLY opt-in, Release and RC never.
        HomeFlightRecording.install(available: DevTools.isEnabled,
                                    logFolder: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "cmux")
    }

    /// Observes the local daemon: each new connection that serves
    /// conversations reloads the list and every open session, then resends
    /// what is still sending (same keys; the owner applies each once).
    func start() {
        services.machines.local.store.sideEvents.subscribe { [weak self] event in self?.handle(event) }
        let local = services.machines.local
        let auth = services.cloud.auth
        // task-owner: lives as long as the service; event-driven (Observation)
        homeObservation = Task { [weak self] in
            // A sign-in or account change re-reads the placed chief (G6), so the Chief tab follows it.
            for await (connection, _) in Observations({
                (local.supports(DaemonCapabilities.shared.workspaceKind) ? local.connection : nil, auth.isSignedIn ? auth.user?.id : nil)
            }) {
                guard let self, let connection else { continue }
                ensureHomeWorkspace(connection)
            }
        }
        startCloud()
        // task-owner: lives as long as the service; event-driven (Observation)
        homeStore.start()
        availability = Task { [weak self] in
            for await connection in Observations({ local.supports(DaemonCapabilities.shared.localConversations) ? local.connection : nil }) {
                guard let self else { continue }
                homeSource.connectionChanged(connection)
                guard let connection else { continue }
                reloadList(connection)
                for session in sessions.values {
                    session.load(from: connection) { [weak self, weak session] in
                        guard let self, let session else { return }
                        for send in session.log.resendable { submit(send, in: session) }
                    }
                }
            }
        }
    }

    var connection: DaemonConnection? { isAvailable ? services.machines.local.connection : nil }

    /// Records the placed chief the last read found (HomeService+Workspace).
    func setCloudChief(_ chief: CloudChief?) {
        if cloudChief != chief { cloudChief = chief }
    }

    /// Home opened in a window: start the local mux's brain host once per launch.
    func homeDidOpen() {
        guard !startedBrainHost, let connection else { return }
        // task-owner: reads the endpoint, then spawns the detached host once
        Task { [weak self] in
            guard let self, let socket = await connection.endpoint?.socketPath,
                  let host = HomeBrainHost.resolve(daemonSocket: socket, controlSocket: services.environment.launch.socketPath,
                                                       tag: services.environment.tag) else { return }
            guard !startedBrainHost else { return }
            startedBrainHost = true
            // The mux proves its principal with a token this (user) connection mints.
            do {
                let token = try await ConversationClient(connection).agentToken(for: HomeService.mux.id)
                await host.launch(agentToken: token)
            } catch {
                startedBrainHost = false
                logger.error("mux agent token: \(String(describing: error), privacy: .public)")
            }
        }
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
            } catch {
                self?.logger.error("conversation-list: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Events

    private func handle(_ event: DaemonEvent) {
        switch event {
        case .conversationChanged(let changed):
            updateList(changed)
            homeSource.publish(changed, summary: conversations.first { $0.id == changed.conversation })
            guard let session = sessions[changed.conversation] else { return }
            if !session.apply(changed), let connection { session.load(from: connection) }
        case .conversationTyping(let typing):
            sessions[typing.conversation]?.setTyping(typing.participant, on: typing.on)
            homeSource.publish(.typing(ConversationID(typing.conversation), ParticipantID(typing.participant), on: typing.on))
        case .cloudConversations(let event):
            handleCloud(event)
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
