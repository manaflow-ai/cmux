import Foundation

/// The tones a chat gives the sessions that message it, as the Mac's
/// `webviews/src/agent-session/acpmux/subagents/agentTones.ts` `agentTones` gives its agents theirs:
/// in start order each takes its id's hash tone (`hashTone`) unless a sibling holds
/// it, then the next tone fewest siblings hold, so up to five never share one (Leo, 2026-11-04: "Each
/// subagent gets its own colour"). A session keeps the tone it was given while that tone is still one
/// of the least used. Case for case with the Mac in `AgentSenderIconTests`.
struct AgentTones {
    /// What the assignment reads of a session: its id and when it started (the phone: when the chat
    /// first heard from it).
    struct Agent: Hashable, Sendable {
        var id: String
        var startedAt: Double?
    }

    /// How many tones there are (the Mac's `AGENT_TONES`).
    static let count = 5
    /// How many assignments are kept; the oldest goes first (the Mac's `ASSIGNED_LIMIT`).
    static let limit = 4096

    private var assigned: [String: Int] = [:]
    /// `assigned`'s keys, oldest first, for the limit.
    private var order: [String] = []

    /// The tones of `agents`, by id.
    mutating func assign(_ agents: [Agent]) -> [String: Int] {
        let byStart = agents.sorted { a, b in
            let x = a.startedAt ?? .infinity, y = b.startedAt ?? .infinity
            return x != y ? x < y : a.id < b.id
        }
        // Sessions already colored go first, so one found later (older history) never takes their tone.
        let ordered = byStart.filter { assigned[$0.id] != nil } + byStart.filter { assigned[$0.id] == nil }
        var uses = [Int](repeating: 0, count: Self.count)
        var tones: [String: Int] = [:]
        for agent in ordered where tones[agent.id] == nil {
            let kept = assigned[agent.id]
            let least = uses.min() ?? 0
            var tone = kept.flatMap { uses[$0] == least ? $0 : nil }
            if tone == nil {
                let start = Self.hashTone(agent.id)
                tone = (0..<Self.count).lazy.map { (start + $0) % Self.count }.first { uses[$0] == least }
            }
            let chosen = tone ?? Self.hashTone(agent.id)
            uses[chosen] += 1
            tones[agent.id] = chosen
            if kept != chosen { keep(agent.id, chosen) }
        }
        return tones
    }

    /// The Mac's `hashTone`: FNV-1a of the UTF-16 units, modulo the tones.
    static func hashTone(_ id: String) -> Int {
        var hash: UInt32 = 0x811c9dc5
        for unit in id.utf16 { hash = (hash ^ UInt32(unit)) &* 0x01000193 }
        return Int(hash % UInt32(count))
    }

    private mutating func keep(_ id: String, _ tone: Int) {
        if assigned[id] != nil { order.removeAll { $0 == id } }
        assigned[id] = tone
        order.append(id)
        if order.count > Self.limit { assigned[order.removeFirst()] = nil }
    }
}
