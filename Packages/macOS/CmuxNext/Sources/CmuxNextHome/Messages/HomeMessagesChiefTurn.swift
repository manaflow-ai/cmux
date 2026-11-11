public import CmuxHomeCore
public import CmuxNextPages
public import CmuxNextSettings

/// What Stop all agents did: the brain's `chief.stop {all}` answer (`ChiefStopAll`).
public struct HomeChiefStopAllAnswer: Sendable, Equatable {
    /// Whether the Chief's own turn was running and stopped.
    public var stopped: Bool
    /// The subagents that stopped, in id order.
    public var subagents: [String]
    /// One line per subagent acpmux refused to stop (it goes on).
    public var errors: [String]
    /// The note about a subagent still starting.
    public var note: String?

    public init(stopped: Bool, subagents: [String], errors: [String] = [], note: String? = nil) {
        self.stopped = stopped
        self.subagents = subagents
        self.errors = errors
        self.note = note
    }
}

/// One skill `/` lists in a Chief's message box: the host's `chief.engine.get` `offered.skills` row.
public struct HomeChiefSlashSkill: Sendable, Equatable {
    public var name: String
    public var description: String
    /// `chief`, `claude` or `plugin:<plugin>`.
    public var source: String

    public init(name: String, description: String, source: String) {
        self.name = name
        self.description = description
        self.source = source
    }
}

/// Why a Chief control did not run, in words the person reads (`HomeChiefEngineError.text`).
public struct HomeMessagesChiefRefusal: Error, Sendable, Equatable {
    public var text: String
    public init(_ text: String) { self.text = text }
}

/// One Chief's turn controls, as the native compose button ran them (`HomeChiefTurnActions`,
/// HomeHostView+StopAll): the brain decides what each does; the page only asks. The engine's
/// `HomeChiefTurnControl` conforms (CmuxNextHomeEngine).
@MainActor
public protocol HomeMessagesChiefControl {
    /// `chief.stop`: true when the running turn stopped (Continue may follow).
    func stopTurn() async -> Result<Bool, HomeMessagesChiefRefusal>
    /// `chief.stop {all: true}`: the Chief's turn and every subagent.
    func stopAllAgents() async -> Result<HomeChiefStopAllAnswer, HomeMessagesChiefRefusal>
    /// `chief.continue`: whether the stopped turn went on, else the brain's reason (`busy`).
    func continueStoppedTurn() async -> Result<(continued: Bool, reason: String?), HomeMessagesChiefRefusal>
    /// `chief.stop {restart: names}` (Restart on the stop-all toast).
    func restartAgents(_ names: [String]) async -> HomeMessagesChiefRefusal?
    /// `chief.stop {start: name}`: Start now on an agent the Chief queued behind its cap (its pill's
    /// card and menu, user 2026-11-08); nil when it started.
    func startQueuedAgent(_ name: String) async -> HomeMessagesChiefRefusal?
    /// `chief.engine.get` `offered.skills`: what `/` in the message box lists.
    func slashSkills() async -> Result<[HomeChiefSlashSkill], HomeMessagesChiefRefusal>
}

/// The Messages page's Chief turn ops (the App's `HomeMessagesHostProvider` routes these here),
/// each on the person's own click or key only:
/// - `chief.stop {conversation}` -> `{stopped}`: the Stop button, Escape and Cmd-. in the message box;
/// - `chief.stopAll {conversation}` -> `{stopped, subagents, errors, note?}`: Option-click on Stop;
/// - `chief.continue {conversation}` -> `{continued, reason?}`: Continue after a stop;
/// - `chief.restart {conversation, names}` -> `{restarted: true}`: Restart on the stop-all toast;
/// - `chief.startAgent {conversation, agent}` -> `{started: true}`: Start now on a queued agent's pill;
/// - `chief.skills {conversation}` -> `{skills: [{name, description, source}]}`: what `/` in the
///   message box lists. A read, so it is the one op a typed `/` runs without a click.
/// A refusal (no Chief here, a hosted cloud Chief, the brain unreachable) throws its words.
@MainActor
public final class HomeMessagesChiefTurn {
    /// The control of the Chief that answers in a conversation; nil: none.
    public typealias Control = @MainActor (ConversationID) -> (any HomeMessagesChiefControl)?
    /// The code of a refused control; the message is the words the page shows.
    public static let refusedCode = "cmux.home.chief.refused"
    static let ops: Set<String> = ["chief.stop", "chief.stopAll", "chief.continue", "chief.restart", "chief.startAgent", "chief.skills"]
    /// The ops that only read: they need no click or key of the person's.
    static let reads: Set<String> = ["chief.skills"]

    private let control: Control

    public init(control: @escaping Control) {
        self.control = control
    }

    /// Answers `name` (the op after `cmux.home.messages.`), or nil when it is not one of these.
    public func call(_ name: String, _ fields: [String: JSONValue], userGesture: Bool) async throws -> JSONValue? {
        guard Self.ops.contains(name) else { return nil }
        guard userGesture || Self.reads.contains(name) else { throw PageError(code: PageNativeOp.userOnlyCode, message: "only the person's own click or key runs this") }
        let id = try HomeMessagesKept.conversation(fields)
        guard let chief = control(id) else { throw PageError(code: Self.refusedCode, message: "") }
        switch name {
        case "chief.stop":
            return .object(["stopped": .bool(try Self.answer(await chief.stopTurn()))])
        case "chief.stopAll":
            let answer = try Self.answer(await chief.stopAllAgents())
            var out: [String: JSONValue] = [
                "stopped": .bool(answer.stopped),
                "subagents": .array(answer.subagents.map(JSONValue.string)),
                "errors": .array(answer.errors.map(JSONValue.string)),
            ]
            if let note = answer.note { out["note"] = .string(note) }
            return .object(out)
        case "chief.continue":
            let answer = try Self.answer(await chief.continueStoppedTurn())
            var out: [String: JSONValue] = ["continued": .bool(answer.continued)]
            if let reason = answer.reason { out["reason"] = .string(reason) }
            return .object(out)
        case "chief.skills":
            let skills = try Self.answer(await chief.slashSkills())
            return .object(["skills": .array(skills.map { skill in
                .object(["name": .string(skill.name), "description": .string(skill.description), "source": .string(skill.source)])
            })])
        case "chief.startAgent":
            let agent = fields["agent"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !agent.isEmpty else { throw PageError.invalidParams("agent must name the queued agent") }
            if let refusal = await chief.startQueuedAgent(agent) { throw PageError(code: Self.refusedCode, message: refusal.text) }
            return .object(["started": .bool(true)])
        default:
            let names = (fields["names"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.isEmpty }
            guard !names.isEmpty else { throw PageError.invalidParams("names must list the agents to restart") }
            if let refusal = await chief.restartAgents(names) { throw PageError(code: Self.refusedCode, message: refusal.text) }
            return .object(["restarted": .bool(true)])
        }
    }

    private static func answer<T>(_ result: Result<T, HomeMessagesChiefRefusal>) throws -> T {
        switch result {
        case .success(let value): return value
        case .failure(let refusal): throw PageError(code: refusedCode, message: refusal.text)
        }
    }
}
