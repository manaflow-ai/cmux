import CmuxHomeCore
import Foundation
import Synchronization

/// One Home inbox over two owners: the local daemon's conversations and the
/// cloud's (`ConversationSummary.owner`). It routes each read and op to the
/// owner of its conversation and leaves every value as that owner sent it;
/// conversation streams pass through unchanged.
///
/// The two owners' inbox streams are separate logs with unrelated
/// revisions, so the merged `.inbox` stream gets its own: one per inbox
/// event this router publishes (the store only needs them dense and
/// increasing). The connection is the local daemon's, which carries both.
nonisolated final class HomeSourceRouter: HomeSource {
    private struct State {
        var continuations: [UUID: AsyncStream<HomeEvent>.Continuation] = [:]
        var lastConnection: HomeEvent?
        var lastInbox: HomeEvent?
        /// The owner of every conversation either source reported. An owner
        /// is a property of the id: it stays when the conversation leaves
        /// the merged inbox, so a cloud id never routes to the local daemon
        /// (the cloud refuses what this account may not do). A new cloud
        /// account drops the previous one's cloud ids it does not list.
        var owners: [ConversationID: ConversationSummary.Owner] = [:]
        /// Cloud conversations in the merged inbox now: listed by the cloud
        /// inbox, or shown by a conversation stream event or page.
        var cloudListed: Set<ConversationID> = []
        var inboxRev: Revision = 0
        var started = false
        /// The account the cloud source acted as at its last inbox, once one
        /// arrived. A change prunes the cloud owners the new inbox does not list.
        var cloudAccount: String?
        var cloudAccountSeen = false
    }

    private let state = Mutex(State())
    private static let eventBuffer = 1024
    let local: any HomeSource
    let cloud: CloudHomeSource
    // task-owner: one consumer per child stream, cancelled with the router
    private let consumers = Mutex<[Task<Void, Never>]>([])

    init(local: any HomeSource, cloud: CloudHomeSource) {
        self.local = local
        self.cloud = cloud
    }

    deinit {
        for task in consumers.withLock({ $0 }) { task.cancel() }
    }

    // MARK: HomeSource

    func events() async -> AsyncStream<HomeEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<HomeEvent>.makeStream(bufferingPolicy: .bufferingNewest(Self.eventBuffer))
        let start = state.withLock { state -> Bool in
            state.continuations[id] = continuation
            let replay = [state.lastConnection ?? .connection(.connecting)] + (state.lastInbox.map { [$0] } ?? [])
            for event in replay { continuation.yield(event) }
            defer { state.started = true }
            return !state.started
        }
        continuation.onTermination = { [weak self] _ in
            // Never take the state lock here: the stream may run this under its
            // own lock while `publish` yields under the state lock (a deadlock).
            // task-owner: one removal; ends at once
            Task { [weak self] in self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) } }
        }
        if start { await startConsuming() }
        return stream
    }

    func inbox() async throws -> InboxSnapshot {
        let localInbox = try await local.inbox()
        // Refreshes what the cloud source knows; a cloud failure must not hide local conversations.
        _ = try? await cloud.inbox()
        // The cloud part is read under the lock that stamps the merged revision,
        // so no cloud inbox event published in between carries a lower one.
        return state.withLock { merged(local: localInbox, cloud: cloud.currentInbox().conversations, &$0) }
    }

    func snapshot(of conversation: ConversationID, tail: Int) async throws -> ConversationPage {
        let page = try await source(for: conversation).snapshot(of: conversation, tail: tail)
        state.withLock { $0.owners[conversation] = page.conversation.owner }
        return page
    }

    func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> [Message] {
        try await source(for: conversation).history(of: conversation, before: beforeSeq, limit: limit)
    }

    /// Ops on a conversation go to its owner. Ops that create or invite name
    /// no conversation and only the cloud has them; `createChief` stays with
    /// the local owner, which refuses it as before.
    func submit(_ intent: HomeIntent) async throws -> HomeOpResult {
        let toCloud: Bool
        switch intent.op {
        case .createGroup, .startConversation, .invite: toCloud = true
        case .createChief: toCloud = false
        default:
            if let conversation = intent.op.conversation { toCloud = await owner(of: conversation) == .cloud } else { toCloud = false }
        }
        guard toCloud else { return try await local.submit(intent) }
        let result = try await cloud.submit(intent)
        if let created = result.conversation { state.withLock { $0.owners[created] = .cloud } }
        return result
    }

    /// Home search is local only until the cloud has `home.search`.
    func search(_ query: String, limit: Int) async throws -> [HomeSearchHit] {
        try await local.search(query, limit: limit)
    }

    func resolve(_ contact: ContactAddress) async throws -> ContactResolution {
        try await cloud.resolve(contact)
    }

    /// A closed transcript goes to its owner; one no owner reported was
    /// never opened on the cloud, and the local owner ignores it.
    func close(_ conversation: ConversationID) {
        if state.withLock({ $0.owners[conversation] }) == .cloud { cloud.close(conversation) } else { local.close(conversation) }
    }

    // MARK: Routing

    /// The owner that reported `conversation`.
    func source(for conversation: ConversationID) async -> any HomeSource {
        await owner(of: conversation) == .cloud ? cloud : local
    }

    /// The owner of `conversation`. One that no owner reported yet (a deep
    /// link or a notification before the merged inbox loads) is looked up
    /// in the cloud inbox first, so a conversation the cloud inbox lists
    /// never reaches the local daemon. One the cloud inbox does not list is
    /// local, as before the cloud existed: that includes a cloud id the
    /// signed-in account cannot see (another account's after a switch, or
    /// one not listed yet), which the local daemon refuses as unknown. The
    /// lookup records owners only: the merged inbox keeps its revisions,
    /// which only events the store receives may move.
    func owner(of conversation: ConversationID) async -> ConversationSummary.Owner {
        if let known = state.withLock({ $0.owners[conversation] }) { return known }
        let listed = (try? await cloud.inbox()) ?? cloud.currentInbox()
        return state.withLock { state in
            for summary in listed.conversations where state.owners[summary.id] == nil { state.owners[summary.id] = .cloud }
            return state.owners[conversation] ?? .local
        }
    }

    private func startConsuming() async {
        let localStream = await local.events()
        let cloudStream = await cloud.events()
        let tasks = [
            Task { [weak self] in
                for await event in localStream {
                    guard let self else { return }
                    forwardLocal(event)
                }
            },
            Task { [weak self] in
                for await event in cloudStream {
                    guard let self else { return }
                    forwardCloud(event)
                }
            },
        ]
        consumers.withLock { $0 = tasks }
    }

    private func forwardLocal(_ event: HomeEvent) {
        publish { state in
            switch event {
            case .connection:
                state.lastConnection = event
                return event
            case .inbox(let snapshot):
                return .inbox(merged(local: snapshot, cloud: cloud.currentInbox().conversations, &state))
            case .conversationChanged(let summary, _, _):
                state.owners[summary.id] = summary.owner
                return event
            default:
                return event
            }
        }
    }

    /// Cloud inbox events are restamped into the merged inbox stream; a
    /// cloud snapshot becomes a diff, so local summaries are never resent
    /// from a stale copy.
    private func forwardCloud(_ event: HomeEvent) {
        switch event {
        case .connection:
            // The local daemon's connection is the merged one. The cloud side
            // reports its own recovery as `.ownerRecovered`, which passes through.
            return
        case .inbox(let snapshot):
            let listed = Set(snapshot.conversations.map(\.id))
            let account = cloud.accountID
            let removed = state.withLock { state -> Set<ConversationID> in
                if state.cloudAccountSeen, state.cloudAccount != account {
                    // Another account: the previous one's cloud ids no longer
                    // route anywhere it can reach; a lookup finds them again.
                    state.owners = state.owners.filter { $0.value == .local || listed.contains($0.key) }
                }
                state.cloudAccount = account
                state.cloudAccountSeen = true
                return state.cloudListed.subtracting(listed)
            }
            for id in removed.sorted(by: { $0.rawValue < $1.rawValue }) {
                publish { state in
                    state.cloudListed.remove(id)
                    state.inboxRev += 1
                    return .conversationRemoved(id, inboxRev: state.inboxRev)
                }
            }
            for summary in snapshot.conversations {
                publish { state in
                    state.cloudListed.insert(summary.id)
                    state.owners[summary.id] = .cloud
                    state.inboxRev += 1
                    return .conversationChanged(summary, stream: .inbox, rev: state.inboxRev)
                }
            }
        case .conversationChanged(let summary, .inbox, _):
            publish { state in
                state.cloudListed.insert(summary.id)
                state.owners[summary.id] = .cloud
                state.inboxRev += 1
                return .conversationChanged(summary, stream: .inbox, rev: state.inboxRev)
            }
        case .conversationRemoved(let id, _):
            publish { state in
                state.cloudListed.remove(id)
                state.inboxRev += 1
                return .conversationRemoved(id, inboxRev: state.inboxRev)
            }
        case .conversationChanged(let summary, _, _):
            // A conversation stream event lists the conversation in the store
            // too. The cloud inbox keeps listing it while it is open, and the
            // next cloud inbox removes it once it lists it no more.
            publish { state in
                state.cloudListed.insert(summary.id)
                state.owners[summary.id] = .cloud
                return event
            }
        case .conversationPage(let page):
            publish { state in
                state.cloudListed.insert(page.conversation.id)
                state.owners[page.conversation.id] = .cloud
                return event
            }
        default:
            publish { _ in event }
        }
    }

    /// Call with the lock held.
    private func merged(local: InboxSnapshot, cloud: [ConversationSummary], _ state: inout State) -> InboxSnapshot {
        for summary in local.conversations { state.owners[summary.id] = .local }
        for summary in cloud { state.owners[summary.id] = .cloud }
        state.cloudListed = Set(cloud.map(\.id))
        state.inboxRev += 1
        let snapshot = InboxSnapshot(me: local.me, conversations: local.conversations + cloud, rev: state.inboxRev)
        return snapshot
    }

    /// Builds and yields one event under the lock, so restamped revisions
    /// reach subscribers in order.
    private func publish(_ build: (inout State) -> HomeEvent?) {
        state.withLock { state in
            guard let event = build(&state) else { return }
            if case .inbox = event { state.lastInbox = event }
            for continuation in state.continuations.values { continuation.yield(event) }
        }
    }
}
