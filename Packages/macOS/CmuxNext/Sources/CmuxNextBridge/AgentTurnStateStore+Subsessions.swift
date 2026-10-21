public import CmuxNextDaemon

/// The sub-session tree acpmux reports (`startedBy` links, `hub/subsessions.rs`), mirrored beside
/// the turn states: the sidebar nests a chat's sub-sessions under its tab, and a chat's page may
/// open the sessions of its own family. The watch feed writes it; readers observe
/// ``familyRevision`` for the tree and each listed session's record for its facts.
extension AgentTurnStateStore {
    /// How deep a tree walk goes: acpmux bounds depth far below this; a cycle in bad data stops here.
    static let maxSubsessionDepth = 64

    // MARK: Writes (the watch feed)

    /// Sets one session's sub-session facts (nil: a root session, or purged); writes only a change.
    public func setSubsession(_ facts: AgentSubsessionFacts?, session: String,
                              source: String = AgentTurnStateStore.localSource) {
        let held = sessions[session] ?? (facts == nil ? nil : subsessionRecord(session, source: source))
        guard let record = held, record.subsession != facts else { return }
        let old = record.subsession
        record.subsession = facts
        guard old?.startedBy != facts?.startedBy else { return }
        if let parent = old?.startedBy {
            children[parent]?.remove(session)
            if children[parent]?.isEmpty == true { children[parent] = nil }
        }
        if let parent = facts?.startedBy { children[parent, default: []].insert(session) }
        familyRevision &+= 1
    }

    /// Replaces the sub-session facts of every session of `source`'s watch with its page's.
    public func replaceSubsessions(_ facts: [String: AgentSubsessionFacts], source: String = AgentTurnStateStore.localSource) {
        let own = sessions.compactMap { $0.value.source == source && $0.value.subsession != nil ? $0.key : nil }
        for id in Set(own).union(facts.keys) { setSubsession(facts[id], session: id, source: source) }
    }

    private func subsessionRecord(_ session: String, source: String) -> Session {
        let record = Session()
        record.source = source
        sessions[session] = record
        return record
    }

    // MARK: Reads

    /// The sub-sessions under the chat an agent chat tab shows, at any depth: depth first, each
    /// level in start order. A closed sub-session is left out; its own sub-sessions take its place.
    /// Empty for a chat of another machine or one with no sub-sessions.
    public func subsessions(of ref: AgentSessionRef) -> [AgentSubsessionEntry] {
        guard let chat = ref.session, ref.host == localHost || mirroredHosts.contains(ref.host) else { return [] }
        _ = familyRevision
        var entries: [AgentSubsessionEntry] = []
        var visited: Set<String> = [chat]
        func walk(_ parent: String, depth: Int, level: Int) {
            guard level <= Self.maxSubsessionDepth else { return }
            let kids = (children[parent] ?? []).compactMap { id in sessions[id].map { (id, $0) } }
                .sorted { ($0.1.subsession?.createdAtMs ?? 0, $0.0) < ($1.1.subsession?.createdAtMs ?? 0, $1.0) }
            for (id, record) in kids where visited.insert(id).inserted {
                guard let facts = record.subsession, facts.startedBy == parent else { continue }
                if facts.closed {
                    walk(id, depth: depth, level: level + 1)
                    continue
                }
                entries.append(AgentSubsessionEntry(session: id, depth: depth, facts: facts, state: record.state, title: record.title))
                walk(id, depth: depth + 1, level: level + 1)
            }
        }
        walk(chat, depth: 1, level: 1)
        return entries
    }

    /// Whether `session` belongs to chat `chat`'s family: a sub-session under it at any depth, or
    /// the session that started it. What the chat's page may open beside it (`chat.offer.open`,
    /// `chat.openTab`).
    public func isFamily(_ session: String, of chat: String) -> Bool {
        guard session != chat else { return false }
        if sessions[chat]?.subsession?.startedBy == session { return true }
        var current = session
        for _ in 0..<Self.maxSubsessionDepth {
            guard let parent = sessions[current]?.subsession?.startedBy else { return false }
            if parent == chat { return true }
            current = parent
        }
        return false
    }

    /// The parent of every sub-session that is not closed, by sub-session id. Observes the tree.
    public func openSubsessionParents() -> [String: String] {
        _ = familyRevision
        var parents: [String: String] = [:]
        for (parent, ids) in children {
            for id in ids where sessions[id]?.subsession?.closed == false { parents[id] = parent }
        }
        return parents
    }
}
