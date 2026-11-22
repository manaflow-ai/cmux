import Foundation

/// A subagent transcript's footer: what the subagent is doing or how it ended, or, while it runs
/// and its Mac can't be reached, that the Mac is offline (nothing more can come, so no spinner).
struct SubagentFooter: Equatable, Sendable {
    var state: AgentSubagent.State
    /// Its latest tool call's title (shown while it runs).
    var action: String?
    var offline: Bool

    /// The glyph's state: disconnected while offline.
    var glyph: AgentSubagent.State { offline && state == .running ? .disconnected : state }

    var text: String {
        if offline, state == .running {
            return String(localized: "mobile.agentChat.subagent.macOffline", defaultValue: "Mac offline", bundle: .module)
        }
        return state == .running ? (action ?? "Working") : state.label
    }

    init(_ agent: AgentSubagent, offline: Bool) {
        state = agent.state
        action = agent.action
        self.offline = offline
    }
}
