import Foundation

/// One agent's recent history, oldest first, bounded (`limit` events, `textLimit` characters of
/// text each), in memory only. The roster keeps one per terminal (`AgentRoster.timelines`), the
/// app's acpmux mirror one per chat; the workspace hover card merges a workspace's.
public struct AgentTimeline: Sendable, Hashable {
    /// The most events one agent keeps; the oldest goes first.
    public static let limit = 64
    /// The most characters of a prompt or reason kept.
    public static let textLimit = 240

    public private(set) var events: [AgentTimelineEvent] = []

    public init(events: [AgentTimelineEvent] = []) {
        for event in events { append(event) }
    }

    /// The newest event's time, 0 when empty.
    public var lastMs: UInt64 { events.last?.atMs ?? 0 }

    /// Adds `event`, trimming its text; an event equal to the newest (a repeated report) adds nothing.
    public mutating func append(_ event: AgentTimelineEvent) {
        var event = event
        event.text = Self.trimmedText(event.text)
        if let last = events.last, last.kind == event.kind, last.text == event.text, last.atMs == event.atMs { return }
        events.append(event)
        if events.count > Self.limit { events.removeFirst(events.count - Self.limit) }
    }

    /// The text as kept: one line of runs of whitespace, at most `textLimit` characters; nil when empty.
    public static func trimmedText(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return line.count > textLimit ? String(line.prefix(textLimit - 1)) + "…" : line
    }

    /// The moments between two statuses of one terminal's agent: a prompted turn (with its
    /// prompt when the status names one), a start of work, a wait, an end of a turn.
    public static func events(from old: AgentStatus?, to new: AgentStatus, nowMs: UInt64) -> [AgentTimelineEvent] {
        let at = new.sinceMs ?? (new.updatedAtMs > 0 ? new.updatedAtMs : nowMs)
        let agent = new.agent
        switch new.state {
        case .working:
            guard AgentRoster.startsPromptedTurn(from: old, to: new) else { return [] }
            // Out of a wait with the same prompt: the person answered, the same turn goes on.
            if old?.state == .blocked, new.lastPrompt == old?.lastPrompt { return [] }
            if let prompt = new.lastPrompt, new.source == "hook" || prompt != old?.lastPrompt {
                return [AgentTimelineEvent(kind: .prompt, atMs: new.updatedAtMs > 0 ? new.updatedAtMs : at, text: prompt, agent: agent)]
            }
            return [AgentTimelineEvent(kind: .started, atMs: at, agent: agent)]
        case .blocked:
            guard old?.state != .blocked else { return [] }
            return [AgentTimelineEvent(kind: .waiting, atMs: at, agent: agent)]
        case .idle, .done:
            guard old?.state == .working || old?.state == .blocked else { return [] }
            return [AgentTimelineEvent(kind: .finished, atMs: at, agent: agent)]
        case .unknown:
            return []
        }
    }
}
