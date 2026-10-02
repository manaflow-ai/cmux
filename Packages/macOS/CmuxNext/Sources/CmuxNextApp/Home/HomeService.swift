import CmuxNextDaemon
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
    private(set) var conversations: [ConversationSummary] = []
    /// The local daemon serves `local-conversations-v1`.
    var isAvailable: Bool { services.machines.local.supports(DaemonCapabilities.shared.localConversations) }
    @ObservationIgnored private(set) var sessions: [String: HomeConversationSession] = [:]
    @ObservationIgnored unowned let services: AppServices
    @ObservationIgnored private var availability: Task<Void, Never>?
    @ObservationIgnored private var listing: Task<Void, Never>?
    /// The brain host was started on this app launch (it outlives the app).
    @ObservationIgnored private var startedBrainHost = false
    @ObservationIgnored let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")
    /// The local user's participant id in local conversations.
    let actor = ConversationParticipant.localUserID

    init(services: AppServices) {
        self.services = services
    }

    /// Observes the local daemon: each new connection that serves
    /// conversations reloads the list and every open session, then resends
    /// what is still sending (same keys; the owner applies each once).
    func start() {
        services.machines.local.store.onConversationEvent = { [weak self] event in self?.handle(event) }
        let local = services.machines.local
        // task-owner: lives as long as the service; event-driven (Observation)
        availability = Task { [weak self] in
            for await connection in Observations({ local.supports(DaemonCapabilities.shared.localConversations) ? local.connection : nil }) {
                guard let self, let connection else { continue }
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

    /// Home opened in a window: start the local mux's brain host once per launch.
    func homeDidOpen() {
        guard !startedBrainHost, let connection else { return }
        // task-owner: reads the endpoint, then spawns the detached host once
        Task { [weak self] in
            guard let self, let socket = await connection.endpoint?.socketPath,
                  let host = HomeBrainHost.resolve(daemonSocket: socket, tag: services.environment.tag) else { return }
            guard !startedBrainHost else { return }
            startedBrainHost = true
            await host.launch()
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
                let list = try await connection.listConversations()
                guard let self, !Task.isCancelled else { return }
                conversations = list
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
            guard let session = sessions[changed.conversation] else { return }
            if !session.apply(changed), let connection { session.load(from: connection) }
        case .conversationTyping(let typing):
            sessions[typing.conversation]?.setTyping(typing.participant, on: typing.on)
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
        let request = ConversationOpRequest(conversation: conversation, idempotencyKey: "read:\(actor):\(seq)", actor: actor,
                                            transaction: nil, op: .setReadCursor(seq: seq))
        // task-owner: one conversation-op write; ends with its reply
        Task { [weak self] in
            do { _ = try await connection.conversationOp(request) } catch {
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
        let request = ConversationOpRequest(conversation: send.conversation, idempotencyKey: send.clientMsgID, actor: actor,
                                            transaction: ClientTransactionID(rawValue: send.clientMsgID), op: send.op)
        // task-owner: one conversation-op write; ends with its reply
        Task { [weak self, weak session] in
            do {
                let result = try await connection.conversationOp(request)
                session?.acknowledge(send.clientMsgID, result: result)
            } catch DaemonError.command(_, let message, _) {
                session?.reject(send.clientMsgID, reason: message)
            } catch {
                self?.logger.info("conversation-op deferred to the next connection: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
