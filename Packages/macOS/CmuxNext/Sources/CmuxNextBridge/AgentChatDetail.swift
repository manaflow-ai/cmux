public import CmuxNextDaemon
public import Foundation

/// What the hover card says about an agent chat beyond its state (acpmux's session summary):
/// the model it runs, when its running turn started, and that turn's prompt.
public nonisolated struct AgentChatDetail: Hashable, Sendable {
    public var model: String?
    /// When the running turn started (Unix ms, `turn.startedAt`); nil between turns.
    public var turnStartedAtMs: UInt64?
    /// The running turn's prompt preview (`turn.prompt`).
    public var prompt: String?
    /// What the session does as acpmux decided it (`lane.state`: working, input, idle,
    /// failed, lost) and since when (`lane.since`, Unix ms), for the tab's hover card.
    public var laneState: String?
    public var laneSinceMs: UInt64?
    /// The session's folder (`cwd`).
    public var cwd: String?

    public init(model: String? = nil, turnStartedAtMs: UInt64? = nil, prompt: String? = nil,
                laneState: String? = nil, laneSinceMs: UInt64? = nil, cwd: String? = nil) {
        self.model = model
        self.turnStartedAtMs = turnStartedAtMs
        self.prompt = prompt
        self.laneState = laneState
        self.laneSinceMs = laneSinceMs
        self.cwd = cwd
    }

    /// A summary's detail; nil when it names none of them.
    public static func of(summary: [String: Any]) -> AgentChatDetail? {
        let turn = summary["turn"] as? [String: Any]
        let text = { (value: Any?) -> String? in
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        let lane = summary["lane"] as? [String: Any]
        let detail = AgentChatDetail(model: text(summary["model"]), turnStartedAtMs: (turn?["startedAt"] as? NSNumber)?.uint64Value,
                                     prompt: text(turn?["prompt"]), laneState: text(lane?["state"]),
                                     laneSinceMs: (lane?["since"] as? NSNumber)?.uint64Value, cwd: text(summary["cwd"]))
        return detail == AgentChatDetail() ? nil : detail
    }

    /// The detail of every session of a watch result that has one.
    public static func details(_ result: [String: Any]) -> [String: AgentChatDetail] {
        var details: [String: AgentChatDetail] = [:]
        for summary in (result["sessions"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
            if let id = summary["sessionId"] as? String, let detail = of(summary: summary) { details[id] = detail }
        }
        return details
    }
}
