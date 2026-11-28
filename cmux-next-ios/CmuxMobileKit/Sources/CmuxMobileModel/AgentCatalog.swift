import Foundation

/// What a new agent chat starts with. Both nil is the Mac's choice, as the Mac's
/// New Agent Chat: its default agent and that agent's default model.
public struct AgentChatStart: Hashable, Sendable {
    /// The acpmux harness id (`claude`, `claude-cr`), or nil for the Mac's default.
    public var harness: String?
    /// The model id, or nil for the harness's default model.
    public var model: String?
    /// The effort level (`low`, `high`), or nil for the model's own default.
    public var effort: String?
    /// The mode the chat starts in (one the Mac lets a phone start), or nil for the first.
    public var mode: String?
    /// The agent's other options (`fast-mode: on`), by option id; set before the first prompt.
    public var options: [String: String]

    public init(harness: String? = nil, model: String? = nil, effort: String? = nil, mode: String? = nil,
                options: [String: String] = [:]) {
        self.harness = harness
        self.model = model
        self.effort = effort
        self.mode = mode
        self.options = options
    }

    /// The Mac's default agent and model.
    public static let macDefault = AgentChatStart()
}

/// One model of an agent, as the Mac's model picker lists it.
public struct AgentModelChoice: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    /// Why it can't be used now (the Mac's "unavailable: <reason>"), or nil.
    public var unavailableReason: String?
    /// The effort levels it takes, as the agent's CLI or the Mac's catalog lists them; empty
    /// when the Mac didn't say.
    public var efforts: [String]
    /// The level a chat on it starts at, when the Mac said.
    public var defaultEffort: String?
    /// The release's short name ("Opus 5.5"), as the Mac's picker shows it; nil: ``name``.
    public var shortName: String?
    /// The other ids that run it (Claude Code's `opus` for Opus 5.5).
    public var aliases: [String]
    /// Among the agent's current models (`topModels`); false: an older release.
    public var isCurrent: Bool

    public init(id: String, name: String, unavailableReason: String? = nil, efforts: [String] = [], defaultEffort: String? = nil,
                shortName: String? = nil, aliases: [String] = [], isCurrent: Bool = true) {
        self.id = id
        self.name = name
        self.unavailableReason = unavailableReason
        self.efforts = efforts
        self.defaultEffort = defaultEffort
        self.shortName = shortName
        self.aliases = aliases
        self.isCurrent = isCurrent
    }

    /// What a picker shows: the short name with its version ("Opus 5.5").
    public var displayName: String { shortName ?? name }

    /// Whether `id` runs this model: its own id or one of its aliases.
    public func answers(to id: String) -> Bool { self.id == id || aliases.contains(id) }
}

/// One choice of an agent's setting: an effort level, a mode, or one value of an option.
public struct AgentSettingChoice: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    /// What it does, when the agent says ("Asks before each change").
    public var detail: String?

    public init(id: String, name: String, detail: String? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
    }

    /// A level or mode the Mac names only by id: `xhigh` → "Extra high", `read-only` → "Read only".
    public static func name(for id: String) -> String {
        switch id.lowercased() {
        case "xhigh": return "Extra high"
        case "max": return "Max"
        default:
            let words = id.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }
}

/// One of an agent's own options a new chat can be started with (Fast mode, an agent's own
/// setting), as its chats report it to the Mac (ACP `configOptions`): its id, name and choices.
public struct AgentConfigChoice: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    public var category: String?
    public var choices: [AgentSettingChoice]

    public init(id: String, name: String, category: String? = nil, choices: [AgentSettingChoice]) {
        self.id = id
        self.name = name
        self.category = category
        self.choices = choices
    }

    /// The agent's effort option, whatever it calls it (as acpmux and the Mac's composer read it).
    public var isEffort: Bool { category == "thought_level" || id == "effort" || id == "reasoning_effort" }
}

/// One agent (acpmux harness) of a Mac, as a phone may start it.
public struct AgentHarnessChoice: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    public var family: String
    /// The Mac's default agent (acpmux `defaultHarness`).
    public var isDefault: Bool
    /// Why a phone can't start it, in the Mac's words; nil when it can.
    public var unavailableReason: String?
    public var models: [AgentModelChoice]
    /// The model a new chat starts on (acpmux `start.model`), if the Mac said.
    public var defaultModel: String?
    /// The modes a chat this phone starts may run in, the start mode first (acpmux's
    /// `remote.modes`: modes that ask before each change); empty when the Mac didn't say.
    public var askingModes: [String]
    /// The effort a new chat starts at (acpmux `start.effort`), if the Mac said.
    public var startEffort: String?
    /// The modes its chats report, named (acpmux `reported.modes`): names for ``askingModes``.
    public var reportedModes: [AgentSettingChoice]
    /// Its effort option as its chats report it (`reported.configOptions`), for the levels'
    /// names and for an agent whose models list none.
    public var effortOption: AgentConfigChoice?
    /// Its other options a new chat can start with (`reported.configOptions` less the model,
    /// effort and mode, which have their own pickers).
    public var configOptions: [AgentConfigChoice]

    public init(id: String, name: String, family: String, isDefault: Bool = false, unavailableReason: String? = nil,
                models: [AgentModelChoice] = [], defaultModel: String? = nil, askingModes: [String] = [],
                startEffort: String? = nil, reportedModes: [AgentSettingChoice] = [], effortOption: AgentConfigChoice? = nil,
                configOptions: [AgentConfigChoice] = []) {
        self.id = id
        self.name = name
        self.family = family
        self.isDefault = isDefault
        self.unavailableReason = unavailableReason
        self.models = models
        self.defaultModel = defaultModel
        self.askingModes = askingModes
        self.startEffort = startEffort
        self.reportedModes = reportedModes
        self.effortOption = effortOption
        self.configOptions = configOptions
    }

    /// The model `id` names here: a release by its id or an alias (`opus` → Opus 5.5).
    public func model(_ id: String?) -> AgentModelChoice? {
        guard let id else { return nil }
        return models.first { $0.id == id } ?? models.first { $0.answers(to: id) }
    }

    /// The modes a phone may start a chat in, the start mode first, by the names its chats use.
    public var modes: [AgentSettingChoice] {
        askingModes.map { id in
            reportedModes.first { $0.id == id } ?? AgentSettingChoice(id: id, name: AgentSettingChoice.name(for: id))
        }
    }

    /// The effort levels `model` (nil: the agent's default model) takes: the model's own list,
    /// else its effort option's; named as its chats name them. With neither, the start model
    /// still takes the Mac's start effort (`start.effort`), so the effort the chat is set to is
    /// named before the first send, also when `start.model` is absent (Leo, 2026-11-22: "it
    /// shouldnt just show plain opus 5.5 if it's going to go to medium by default").
    public func efforts(model: String?) -> [AgentSettingChoice] {
        let listed = self.model(model ?? offeredDefaultModel)?.efforts ?? []
        guard !listed.isEmpty else {
            if let options = effortOption?.choices, !options.isEmpty { return options }
            guard let startEffort, startsOn(model) else { return [] }
            return [AgentSettingChoice(id: startEffort, name: AgentSettingChoice.name(for: startEffort))]
        }
        return listed.map { level in
            effortOption?.choices.first { $0.id == level } ?? AgentSettingChoice(id: level, name: AgentSettingChoice.name(for: level))
        }
    }

    /// The level a chat on `model` starts at, among the levels it takes: on the start model the
    /// Mac's start effort (`start.effort`: its saved pick, else the model's default), else the
    /// model's default; on another model its default, else the start effort. Nil only when the
    /// Mac named none of them for this model.
    public func defaultEffort(model: String?) -> String? {
        let offered = efforts(model: model)
        let taken: (String?) -> String? = { level in
            guard let level, offered.contains(where: { $0.id == level }) else { return nil }
            return level
        }
        let own = self.model(model ?? offeredDefaultModel)?.defaultEffort
        return startsOn(model) ? taken(startEffort) ?? taken(own) : taken(own) ?? taken(startEffort)
    }

    /// Whether `model` (nil: the agent's default) is the model a new chat starts on (acpmux
    /// `start.model`, an alias naming its release); nil is, also when the Mac named no model
    /// (a profile that passes its own model to the agent).
    public func startsOn(_ model: String?) -> Bool {
        guard let model else { return true }
        guard let defaultModel else { return false }
        return (self.model(model)?.id ?? model) == (self.model(defaultModel)?.id ?? defaultModel)
    }

    public var canStart: Bool { unavailableReason == nil }

    /// ``defaultModel`` when this Mac's account offers it: a harness that lists its models
    /// and leaves the default out can't run it (full verify D4), so Default is not named.
    public var offeredDefaultModel: String? {
        guard let defaultModel else { return nil }
        guard !models.isEmpty else { return defaultModel }
        // An alias (`opus`) names its release (Opus 5.5).
        return models.first { $0.answers(to: defaultModel) }?.id
    }
}

/// The agents a Mac offers a phone: the Mac's catalog (`_acpmux/harnesses`, `_acpmux/models`)
/// with the remote rules applied, so the menu says what a phone can start and why not.
public struct AgentCatalog: Hashable, Sendable, Codable {
    public var harnesses: [AgentHarnessChoice]
    /// The agent and model the Mac's New Tab page picked last (acpmux `lastPicks`), so the
    /// phone's New Agent Chat starts where the Mac's does; nil when the Mac didn't say.
    public var lastPicks: AgentLastPicks?

    public init(harnesses: [AgentHarnessChoice], lastPicks: AgentLastPicks? = nil) {
        self.harnesses = harnesses
        self.lastPicks = lastPicks
    }

    public static let empty = AgentCatalog(harnesses: [])

    /// What New Agent Chat starts: the Mac's default agent when a phone can start it, else
    /// the first agent a phone can start (Claude before others, as acpmux asks only there).
    public var defaultChoice: AgentHarnessChoice? {
        if let mac = harnesses.first(where: { $0.isDefault && $0.canStart }) { return mac }
        let startable = harnesses.filter(\.canStart)
        // The family's own profile (`claude`) before its variants (`claude-cr`).
        return startable.first { $0.id == "claude" } ?? startable.first { $0.family == "claude" }
            ?? startable.first { $0.id == $0.family } ?? startable.first
    }

    public func harness(_ id: String) -> AgentHarnessChoice? { harnesses.first { $0.id == id } }

    /// The harness and model a start resolves to here; nil when nothing can start. The Mac's
    /// default (`start` names neither) is the Mac's last pick in `folder`, else its last pick
    /// anywhere, else the agent it picked last, else ``defaultChoice``, as the Mac's New Agent
    /// Chat (its `newTab.lastPicks`); a last pick the phone can't start is skipped.
    public func resolve(_ start: AgentChatStart, folder: String? = nil) -> (harness: AgentHarnessChoice, model: String?)? {
        if start.harness == nil, start.model == nil {
            for picked in lastPicks?.picks(in: folder) ?? [] {
                guard let harness = harness(picked.harness), harness.canStart else { continue }
                let model = picked.model.flatMap { $0 == harness.defaultModel || $0 == "default" ? nil : $0 }
                return (harness, model)
            }
        }
        guard let harness = start.harness.map({ harness($0) }) ?? defaultChoice, harness.canStart else { return nil }
        guard let model = start.model, model != "default" else {
            // Default on a named agent: the Mac's own pick for that agent (in `folder`, else
            // anywhere), so a phone's chat runs the model the Mac's chats do (full verify D4).
            let picked = lastPicks?.picks(in: folder).first { $0.harness == harness.id }?.model
            return (harness, picked.flatMap { $0 == harness.defaultModel || $0 == "default" ? nil : $0 })
        }
        guard model != harness.defaultModel else { return (harness, nil) }
        return (harness, model)
    }

    /// The remote start rule a phone mirrors from acpmux (`web_modes.rs` `REFUSED_FAMILIES`):
    /// families with no mode that asks before each change are never started over the link.
    public static let refusedFamilies: Set<String> = ["codex", "opencode"]
    /// The Mac's own words for them on a remote device (`composer.remoteUnavailable`).
    public static let refusedReason = "Not available from here: this agent has no mode that asks before each change"

    /// Why New Agent Chat can't start anything, in one line; nil when it can.
    public var unavailableReason: String? {
        guard defaultChoice == nil else { return nil }
        if harnesses.isEmpty { return "No agents are set up in cmux on this Mac." }
        return harnesses.first(where: \.isDefault)?.unavailableReason ?? harnesses.first?.unavailableReason
    }
}


/// The agent and model a Mac's New Tab page picked last, anywhere and per folder
/// (the Mac's `newTab.lastAgent` and `newTab.lastPicks`, through acpmux `lastPicks`).
public struct AgentLastPicks: Hashable, Sendable, Codable {
    public struct Pick: Hashable, Sendable, Codable {
        public var harness: String
        /// nil: the agent alone was picked (its own default model).
        public var model: String?

        public init(harness: String, model: String? = nil) {
            self.harness = harness
            self.model = model
        }
    }

    public var lastAgent: String?
    public var global: Pick?
    /// Keyed by absolute folder.
    public var folders: [String: Pick]

    public init(lastAgent: String? = nil, global: Pick? = nil, folders: [String: Pick] = [:]) {
        self.lastAgent = lastAgent
        self.global = global
        self.folders = folders
    }

    /// The pick in `folder`, then the pick anywhere, then the agent picked last.
    public func picks(in folder: String?) -> [Pick] {
        [folder.flatMap { folders[$0] }, global, lastAgent.map { Pick(harness: $0) }].compactMap { $0 }
    }
}

extension NewTabKind {
    /// The Mac's default agent chat.
    public static let agentChat = NewTabKind.agent(.macDefault)
}
