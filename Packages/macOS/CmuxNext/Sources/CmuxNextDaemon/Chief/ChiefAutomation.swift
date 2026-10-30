import Foundation

/// One of the Chief's automations (optchat-chief automations.rs, issue 25573), as
/// `chief.automation.list` passes the brain's record through: a task the person asked the
/// Chief to run on a schedule or when an event happens.
public struct ChiefAutomation: Decodable, Sendable, Equatable, Identifiable {
    /// What starts it.
    public enum Trigger: Sendable, Equatable {
        /// A five-field cron in the Mac's time zone (`0 9 * * *`).
        case schedule(cron: String)
        /// One of the Chief's subagents finished; `matches`: only one whose title has it.
        case agentDone(matches: String?)
        /// A trigger a newer brain names that this app does not know.
        case other(String)
    }

    /// `au<N>`.
    public var id: String
    public var name: String
    public var prompt: String
    public var trigger: Trigger
    public var paused: Bool
    /// A schedule's next fire, in milliseconds since 1970; nil while paused or for an event.
    public var nextMs: Double?
    public var lastFiredMs: Double?
    public var runs: Int

    public init(id: String, name: String, prompt: String = "", trigger: Trigger, paused: Bool = false,
                nextMs: Double? = nil, lastFiredMs: Double? = nil, runs: Int = 0) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.trigger = trigger
        self.paused = paused
        self.nextMs = nextMs
        self.lastFiredMs = lastFiredMs
        self.runs = runs
    }

    enum CodingKeys: String, CodingKey {
        case id, name, prompt, trigger, paused, runs
        case nextMs = "next_ms", lastFiredMs = "last_fired_ms"
    }

    enum TriggerKeys: String, CodingKey { case type, cron, matches }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        nextMs = try c.decodeIfPresent(Double.self, forKey: .nextMs)
        lastFiredMs = try c.decodeIfPresent(Double.self, forKey: .lastFiredMs)
        runs = try c.decodeIfPresent(Int.self, forKey: .runs) ?? 0
        let t = try c.nestedContainer(keyedBy: TriggerKeys.self, forKey: .trigger)
        let type = try t.decode(String.self, forKey: .type)
        switch type {
        case "schedule": trigger = .schedule(cron: try t.decodeIfPresent(String.self, forKey: .cron) ?? "")
        case "agent_done": trigger = .agentDone(matches: try t.decodeIfPresent(String.self, forKey: .matches))
        default: trigger = .other(type)
        }
    }
}

/// What `chief.automation.update` does to one automation.
public enum ChiefAutomationAction: String, Sendable, CaseIterable {
    case pause, resume, delete, run
}

/// The brain's `{automations: [...]}` answer.
struct ChiefAutomationList: Decodable, Sendable {
    var automations: [ChiefAutomation]
}
