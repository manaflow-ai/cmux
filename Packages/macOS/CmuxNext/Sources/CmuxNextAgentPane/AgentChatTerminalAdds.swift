import CmuxNextDesign

/// The chat header's Terminal button under Debug Settings `agentChat.terminalButtonAdds`
/// (``AgentPaneTunables/terminalButtonAdds``): how the header's log of the splits it opened
/// (AgentChatSplitToggles, oldest first) changes so the other buttons keep toggling theirs. Off,
/// every rule is the toggling header's own.
public nonisolated struct AgentChatTerminalAdds: Sendable {
    /// The Terminal button's header action.
    public static let terminal = "splitRight"
    /// Whether the toggle is on.
    public let on: Bool

    public init(on: Bool) { self.on = on }
    /// The toggle as Debug Settings has it now.
    public init() { self.init(on: AgentPaneTunables.terminalButtonAdds.value) }

    /// Whether a click of header action `id` adds a split instead of toggling the one it opened.
    public func adds(_ id: String) -> Bool { on && id == Self.terminal }

    /// The buttons that show lit, from those whose last split is open: on, never Terminal, whose
    /// click adds rather than closes.
    public func lit(_ ids: [String]) -> [String] { on ? ids.filter { $0 != Self.terminal } : ids }

    /// `log` with room for one more opening, at most `limit` long. Off, the oldest openings go. On,
    /// an opening some later one of its button replaces goes first (repeated adds), so each other
    /// button keeps its last split and its lit state.
    public func room<Entry>(in log: [Entry], limit: Int, id: (Entry) -> String) -> [Entry] {
        guard on, log.count >= limit else { return Array(log.suffix(limit - 1)) }
        var log = log
        while log.count >= limit {
            let ids = log.map(id)
            let stale = ids.indices.first { ids[($0 + 1)...].contains(ids[$0]) } ?? 0
            log.remove(at: stale)
        }
        return log
    }

    /// `log` after a toggle click on header action `id` forgets its last opening, at `index`. For
    /// Terminal, the openings adds left before it go too, so with the toggle turned off the next
    /// click opens a terminal again instead of closing an older one (toggling keeps one per button).
    public static func forgetting<Entry>(_ index: Int, of id: String, in log: [Entry], id key: (Entry) -> String) -> [Entry] {
        var log = log
        log.remove(at: index)
        if id == terminal { log.removeAll { key($0) == id } }
        return log
    }
}
