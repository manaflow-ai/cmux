public import CmuxHomeCore
import CmuxNextWakeups
public import Foundation

/// The chief experiment as a Home backend (`HomeSource`): one conversation
/// between the person and their chief, plus the workers the chief spawned,
/// fed by the Worker's long poll. The Home store, mirror, intent log and the
/// native transcript are the shared ones; nothing here renders.
///
/// Revisions: the conversation's revision is the seq of its newest message
/// (the Worker's seqs are dense), so the mirror's gap check holds. The inbox
/// revision moves when a new worker joins the participants.
public actor ChiefHomeSource: HomeSource {
    public nonisolated let conversation: ConversationID
    public nonisolated let me: Participant
    public nonisolated let chief: Participant
    private let transport: any ChiefTransport
    private let meName: String
    private let clock: any Clock<Duration>

    private var workers: [String: Participant] = [:]
    private var lastSeq: Seq = 0
    private var lastMessage: Message?
    private var readCursor: Seq = 0
    private var inboxRev: Revision = 1
    private let createdAt: Date

    /// Seconds a poll waits on the Worker before it returns empty.
    static let pollWait = 25

    public init(transport: any ChiefTransport, chiefID: String, meName: String,
                clock: any Clock<Duration> = ContinuousClock(), now: Date = Date()) {
        self.transport = transport
        self.meName = meName
        self.clock = clock
        self.createdAt = now
        conversation = ConversationID("conv_chief_\(chiefID)")
        me = Participant(id: ParticipantID("user_me"), kind: .human, displayName: meName)
        chief = Participant(id: ParticipantID("agent_chief_\(chiefID)"), kind: .agent, displayName: "Chief",
                            agentClass: .chief, ownerUser: ParticipantID("user_me"))
    }

    public init(config: ChiefExperimentConfig) {
        self.init(transport: ChiefHTTPTransport(config: config), chiefID: config.chief, meName: config.me)
    }

    // MARK: Mapping

    private func worker(_ name: String) -> Participant {
        if let known = workers[name] { return known }
        let p = Participant(id: ParticipantID("agent_worker_\(name)"), kind: .agent, displayName: name,
                            agentClass: .agent, ownerUser: me.id)
        workers[name] = p
        return p
    }

    /// A Worker message as a Home message. Errors show as the chief's words.
    func message(_ wire: ChiefWireMessage) -> Message {
        let author: ParticipantID
        let text: String
        switch wire.kind {
        case .human: author = me.id; text = wire.text
        case .chief: author = chief.id; text = wire.text
        case .worker: author = worker(wire.author).id; text = wire.text
        case .error: author = chief.id; text = "⚠︎ \(wire.text)"
        }
        return Message(
            id: MessageID(wire.id),
            conversation: conversation,
            seq: wire.seq,
            clientMessageID: IdempotencyKey(wire.clientMessageID ?? wire.id),
            author: author,
            parts: [.text(text)],
            createdAt: Date(timeIntervalSince1970: wire.at / 1000)
        )
    }

    private func absorb(_ wire: [ChiefWireMessage]) -> (messages: [Message], newWorker: Bool) {
        let before = workers.count
        let messages = wire.map(message)
        if let last = messages.last, last.seq >= lastSeq {
            lastSeq = last.seq
            lastMessage = last
        }
        return (messages, workers.count != before)
    }

    func summary() -> ConversationSummary {
        ConversationSummary(
            id: conversation,
            owner: .cloud,
            title: "Chief (experiment)",
            participants: [me, chief] + workers.values.sorted { $0.displayName < $1.displayName },
            lastSeq: lastSeq,
            rev: lastSeq,
            createdAt: createdAt,
            updatedAt: lastMessage?.createdAt ?? createdAt,
            lastMessage: lastMessage,
            readCursors: [me.id: readCursor],
            pinRank: 0
        )
    }

    private func snapshotValue() -> InboxSnapshot {
        InboxSnapshot(me: me, conversations: [summary()], rev: inboxRev)
    }

    // MARK: HomeSource

    public func events() -> AsyncStream<HomeEvent> {
        // A dropped message shows as a revision jump, which the store refetches.
        let (stream, continuation) = AsyncStream<HomeEvent>.makeStream(bufferingPolicy: .bufferingNewest(512))
        let task = Task { await self.run(continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Connect, publish the inbox, then follow the long poll. A failure goes
    /// offline and retries with backoff; the store refetches what it missed.
    private func run(_ out: AsyncStream<HomeEvent>.Continuation) async {
        out.yield(.connection(.connecting))
        var backoff = Backoff(initial: .seconds(1), maximum: .seconds(30))
        var online = false
        // wakeup-allow: each pass blocks on the Worker's long poll (up to 25 s) and failures wait on Backoff; the store stops this task when the tab closes
        while !Task.isCancelled {
            do {
                if !online {
                    _ = absorb(try await transport.tail(1))
                    online = true
                    backoff.reset()
                    out.yield(.connection(.online))
                    out.yield(.inbox(snapshotValue()))
                }
                let fresh = try await transport.messages(after: lastSeq, wait: Self.pollWait)
                let (messages, newWorker) = absorb(fresh)
                if newWorker {
                    inboxRev += 1
                    out.yield(.conversationChanged(summary(), stream: .inbox, rev: inboxRev))
                }
                for m in messages { out.yield(.message(m, rev: m.seq)) }
            } catch is CancellationError {
                break
            } catch {
                if online { out.yield(.connection(.offline(since: Date()))) }
                online = false
                // concurrency-allow: Backoff.wait is an async sleep after a failure, not a blocking wait.
                do { try await backoff.wait(owner: "chief.poll", clock: clock) } catch { break }
            }
        }
        out.finish()
    }

    public func inbox() async throws -> InboxSnapshot {
        _ = absorb(try await call { try await self.transport.tail(1) })
        return snapshotValue()
    }

    public func snapshot(of id: ConversationID, tail: Int) async throws -> ConversationPage {
        guard id == conversation else { throw HomeRejection.invalid("unknown conversation") }
        let (messages, _) = absorb(try await call { try await self.transport.tail(tail) })
        return ConversationPage(conversation: summary(), messages: messages)
    }

    public func history(of id: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> [Message] {
        guard id == conversation else { throw HomeRejection.invalid("unknown conversation") }
        return try await call { try await self.transport.page(before: beforeSeq, limit: limit) }.map(message)
    }

    public func submit(_ intent: HomeIntent) async throws -> HomeOpResult {
        switch intent.op {
        case .sendMessage(let id, let parts):
            guard id == conversation else { throw HomeRejection.invalid("unknown conversation") }
            let text = parts.map(\.plainText).joined(separator: "\n")
            let sent = try await call { try await self.transport.send(clientID: intent.key.rawValue, text: text, from: self.meName) }
            return HomeOpResult(rev: sent.seq)
        case .setReadCursor(let id, let seq):
            guard id == conversation else { throw HomeRejection.invalid("unknown conversation") }
            // Read state stays on this Mac in the experiment; the Worker has no cursors.
            readCursor = max(readCursor, min(seq, lastSeq))
            return HomeOpResult(rev: lastSeq)
        default:
            throw HomeRejection.invalid("The chief experiment supports messages only.")
        }
    }

    public func search(_ query: String, limit: Int) async throws -> [HomeSearchHit] { [] }

    public func resolve(_ contact: ContactAddress) async throws -> ContactResolution {
        throw HomeRejection.invalid("The chief experiment has no contacts.")
    }

    /// Maps transport failures onto the store's rejections.
    private func call<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as ChiefTransportError {
            switch error {
            case .unreachable: throw HomeRejection.ownerUnreachable
            case .unauthorized: throw HomeRejection.notAuthorized
            case .invalid(let why): throw HomeRejection.invalid(why)
            case .server: throw HomeRejection.indeterminate
            }
        }
    }
}
