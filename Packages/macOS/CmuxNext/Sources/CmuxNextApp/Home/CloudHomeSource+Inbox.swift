import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Synchronization

extension CloudHomeSource {
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
        guard let commands, let identity, leased else { return state.withLock { snapshot(&$0) } }
        let list = try await reply(for: identity) { try await commands.inboxList(limit: Self.inboxLimit) }
        let (inbox, missing, unlisted, current) = state.withLock { state -> (InboxSnapshot, [ConversationID], [ConversationID],
                                                                             (any CloudConversationCommands)?) in
            guard state.generation == generation else { return (snapshot(&state), [], [], nil) }
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
            let unlisted = gone.filter { forget($0, &state) }
            return (snapshot(&state), needsHead(state), unlisted, state.commands)
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
    func currentInbox() -> InboxSnapshot { state.withLock { snapshot(&$0) } }

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
            return ConversationPage(conversation: joined(conversation, state) ?? summary,
                                    messages: page.messages.map { CloudHomeMapping.message($0, identity: identity) })
        }
    }

    fileprivate func snapshot(_ state: inout State) -> InboxSnapshot {
        state.inboxRev += 1
        let open = Set(state.targets.keys).subtracting(state.entries.keys).subtracting(state.created).subtracting(state.removed)
        let conversations = state.entries.keys.compactMap { joined($0, state) }
            + state.created.subtracting(state.entries.keys).compactMap { joined($0, state) }
            + open.compactMap { joined($0, state) }
        return InboxSnapshot(me: me, conversations: conversations, rev: state.inboxRev)
    }

    /// Whether a conversation belongs to this generation's account: listed,
    /// created or subscribed since the last account change. A stream event
    /// of any other conversation is dropped: it can only be a previous
    /// account's, arriving after the switch (the daemon had not yet
    /// processed the unsubscribe, or reopened the socket).
    fileprivate func known(_ id: ConversationID, _ state: State) -> Bool {
        state.targets[id] != nil || state.entries[id] != nil || state.created.contains(id)
    }

    /// Whether a conversation stream event may change what the store shows:
    /// only for this account's conversations, and not while UserDO has
    /// taken the conversation out of the inbox (UserDO owns inbox
    /// membership, home-messaging.md 4.2).
    fileprivate func mayShow(_ id: ConversationID, _ state: State) -> Bool {
        known(id, state) && !state.removed.contains(id)
    }

    /// Drops what this source kept for a conversation the inbox no longer
    /// lists: its head, and its subscription, so its stream cannot list it
    /// again. Returns whether a subscription must end.
    fileprivate func forget(_ id: ConversationID, _ state: inout State) -> Bool {
        state.heads[id] = nil
        state.recent.removeAll { $0 == id }
        return state.targets.removeValue(forKey: id) != nil
    }

    /// The head with the inbox's pin and mute, or the entry alone.
    fileprivate func joined(_ id: ConversationID, _ state: State) -> CmuxHomeCore.ConversationSummary? {
        guard let identity = state.identity else { return nil }
        let entry = state.entries[id]
        guard var summary = state.heads[id] else { return entry.map { CloudHomeMapping.summary($0, identity: identity) } }
        if let entry { CloudHomeMapping.apply(entry, to: &summary) }
        return summary
    }

    /// A listed conversation whose head is missing, or behind its entry's
    /// newest message (the preview), unless its socket keeps the head
    /// current. Pin, mute and unread come from the entry itself
    /// (`CloudHomeMapping.apply`), so those changes read nothing.
    fileprivate func needsHead(_ id: ConversationID, _ state: State) -> Bool {
        guard let entry = state.entries[id], state.targets[id] == nil else { return false }
        guard let head = state.heads[id] else { return true }
        return entry.lastSeq > head.lastSeq
    }

    fileprivate func needsHead(_ state: State) -> [ConversationID] {
        state.entries.keys.filter { needsHead($0, state) }.sorted { $0.rawValue < $1.rawValue }
    }

    /// A participant for `conversation.create`, as a known head names it.
    fileprivate func participantRecord(_ id: ParticipantID, identity: CloudIdentity, _ state: State) -> ConversationParticipant {
        let known = state.heads.values.lazy.flatMap(\.participants).first { $0.id == id }
        let wireID = identity.toCloud(id)
        let isAgent = known.map { $0.kind == .agent } ?? wireID.hasPrefix("agent_")
        return ConversationParticipant(id: wireID, kind: isAgent ? .agent : .human, displayName: known?.displayName ?? wireID,
                                       agentClass: isAgent ? (known?.agentClass == .chief ? "mux" : "agent") : nil)
    }

    /// The transport and account for a read, or for an intent whose key
    /// `binding` names: that key now belongs to this account, unless a
    /// previous account submitted it. Without the daemon's lease for this
    /// account nothing goes out (a reply could be another account's): the
    /// refusal waits (`ownerUnreachable`) and asks the link for a lease.
}
