import CmuxHomeCore
import CmuxNextDaemon
import Foundation

nonisolated extension CloudHomeSource {
    // MARK: HomeSource

    func events() async -> AsyncStream<HomeEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<HomeEvent>.makeStream(bufferingPolicy: .bufferingNewest(Self.eventBuffer))
        state.withLock { state in
            state.continuations[id] = continuation
            for event in state.lastEvent.isEmpty ? [.connection(.connecting)] : state.lastEvent { continuation.yield(event) }
        }
        continuation.onTermination = { [weak self] _ in
            // Never take the state lock here: the stream may run this under its
            // own lock while `publish` yields under the state lock (a deadlock).
            // task-owner: one removal; ends at once
            Task { [weak self] in self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) } }
        }
        return stream
    }

    /// The cloud inbox; empty while signed out or without the transport.
    /// Without the lease it reads nothing (the daemon may still hold the
    /// previous account's) and answers what this source knows.
    func inbox() async throws -> InboxSnapshot {
        let (commands, identity, generation, leased) = state.withLock { ($0.commands, $0.identity, $0.generation, $0.leased) }
        guard let commands, let identity, leased else { return state.withLock { $0.snapshot(me: me) } }
        let list = try await reply(for: identity) { try await commands.inboxList(limit: Self.inboxLimit) }
        let (inbox, missing, unlisted, current) = state.withLock { state -> (InboxSnapshot, [ConversationID], [ConversationID],
                                                                             (any CloudConversationCommands)?) in
            guard state.generation == generation else { return (state.snapshot(me: me), [], [], nil) }
            var entries = Dictionary(list.entries.filter(\.isListed).map { (ConversationID($0.conversation), $0) },
                                     uniquingKeysWith: { $1 })
            if let revision = Self.revision(list.revision) {
                // An inbox event newer than this reply wins: its entry, or its absence.
                for (id, seq) in state.touched where seq > revision { entries[id] = state.entries[id] }
                state.touched = state.touched.filter { $0.value > revision }
            }
            state.created.subtract(entries.keys)
            state.removed.subtract(entries.keys)
            // Listed again since its socket closed: the user is back in it.
            state.closed.subtract(entries.keys.filter { state.entries[$0] == nil })
            let gone = state.entries.keys.filter { entries[$0] == nil && !state.created.contains($0) }
            state.removed.formUnion(gone)
            state.entries = entries
            let unlisted = gone.filter { state.forget($0) }
            return (state.snapshot(me: me), state.missingHeads(), unlisted, state.commands)
        }
        unsubscribe(unlisted, commands: current)
        hydrate(missing, generation: generation)
        return inbox
    }

    #if DEBUG
    /// Conversations queued for or in a hydration read (tests).
    var queuedHydrations: Int { state.withLock { $0.hydrating.count } }

    /// Runs `seam` inside every later `snapshot(of:)`, between marking the
    /// conversation viewed and subscribing it (tests).
    func setSnapshotWillSubscribe(_ seam: (@Sendable () async -> Void)?) {
        state.withLock { $0.snapshotWillSubscribe = seam }
    }
    #endif

    /// The cloud part of the inbox as this source knows it now (no read).
    func currentInbox() -> InboxSnapshot { state.withLock { $0.snapshot(me: me) } }

    func snapshot(of conversation: ConversationID, tail: Int) async throws -> ConversationPage {
        let (commands, identity, generation) = try requireEndpoint()
        // The user opens it: a socket the owner closed may be allowed now.
        state.withLock { state in
            state.closed.remove(conversation)
            state.viewed.insert(conversation)
        }
        #if DEBUG
        if let seam = state.withLock({ $0.snapshotWillSubscribe }) { await seam() }
        #endif
        await subscribe(conversation, commands: commands, generation: generation)
        let page = try await reply(for: identity) { try await commands.snapshot(conversation.rawValue, tail: tail) }
        let summary = CloudHomeMapping.summary(page.conversation, identity: identity)
        return state.withLock { state in
            if state.generation == generation {
                state.heads[conversation] = summary
                // The user opened it (and has not closed it since): its stream may show it again.
                if state.viewed.contains(conversation) { state.removed.remove(conversation) }
            }
            return ConversationPage(conversation: state.joined(conversation) ?? summary,
                                    messages: page.messages.map { CloudHomeMapping.message($0, identity: identity) })
        }
    }

    func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> [Message] {
        let (commands, identity, _) = try requireEndpoint()
        let page = try await reply(for: identity) { try await commands.history(conversation.rawValue, before: beforeSeq, limit: limit) }
        return page.messages.map { CloudHomeMapping.message($0, identity: identity) }
    }

    /// Binds the intent's key to the signed-in account first: a key a
    /// previous account submitted is refused (`notAuthorized`, the store
    /// drops it) and never reaches the daemon under this account's lease.
    func submit(_ intent: HomeIntent) async throws -> HomeOpResult {
        if case .setTyping(let conversation, _) = intent.op {
            // Typing is not in cloud-conversations-v1 part 1: nothing is sent or
            // resent, so the key is not bound to the account.
            return HomeOpResult(rev: 0, conversation: conversation)
        }
        let key = intent.key.rawValue
        let (commands, identity, generation) = try requireEndpoint(binding: key)
        let result: HomeOpResult
        do {
            result = try await run(intent, commands: commands, identity: identity, generation: generation)
        } catch let rejection as HomeRejection {
            // Refused for good: the store never resends it. A refused send stays
            // bound, because the user may send it again with the same key.
            if Self.isFinal(rejection), !Self.isSend(intent.op) { state.withLock { _ = $0.accepted.remove(key) } }
            throw rejection
        }
        // Committed: the store never sends this key again.
        state.withLock { _ = $0.accepted.remove(key) }
        return result
    }

    private static func isSend(_ op: HomeOp) -> Bool {
        if case .sendMessage = op { true } else { false }
    }

    /// A refusal the store does not resend.
    static func isFinal(_ rejection: HomeRejection) -> Bool {
        switch rejection {
        case .invalid, .notAuthorized: true
        default: false
        }
    }

    /// The transcript left the screen ("open" means on screen now): its
    /// subscription ends, and a conversation the inbox does not list (one
    /// opened from the archive, a deep link or a notification) leaves the
    /// inbox. A listed one stays as UserDO lists it.
    func close(_ conversation: ConversationID) {
        var ending: (any CloudConversationCommands)?
        publish { state in
            state.viewed.remove(conversation)
            // The close ends the subscription an edit kept, too.
            state.editHolds.removeValue(forKey: conversation)?.deadline.cancel()
            guard state.targets.removeValue(forKey: conversation) != nil else { return nil }
            state.recent.removeAll { $0 == conversation }
            ending = state.commands
            guard state.entries[conversation] == nil, !state.created.contains(conversation) else { return nil }
            state.heads[conversation] = nil
            state.inboxRev += 1
            return .conversationRemoved(conversation, inboxRev: state.inboxRev)
        }
        unsubscribe([conversation], commands: ending)
    }

    /// Home search is not in cloud-conversations-v1 part 1.
    func search(_ query: String, limit: Int) async throws -> [HomeSearchHit] { [] }

    /// `dm.open` resolves addresses on the owner and answers the same whether
    /// or not the address has an account, so the client cannot tell.
    func resolve(_ contact: ContactAddress) async throws -> ContactResolution { .invitable(contact) }
}
