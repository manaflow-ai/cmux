import Foundation

/// What a new agent chat starts with. Both nil is the Mac's choice, as the Mac's
/// New Agent Chat: its default agent and that agent's default model.
public struct AgentChatStart: Hashable, Sendable {
    /// The acpmux harness id (`claude`, `claude-cr`), or nil for the Mac's default.
    public var harness: String?
    /// The model id, or nil for the harness's default model.
    public var model: String?

    public init(harness: String? = nil, model: String? = nil) {
        self.harness = harness
        self.model = model
    }

    /// The Mac's default agent and model.
    public static let macDefault = AgentChatStart()
}

/// One model of an agent, as the Mac's model picker lists it.
public struct AgentModelChoice: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Why it can't be used now (the Mac's "unavailable: <reason>"), or nil.
    public var unavailableReason: String?

    public init(id: String, name: String, unavailableReason: String? = nil) {
        self.id = id
        self.name = name
        self.unavailableReason = unavailableReason
    }
}

/// One agent (acpmux harness) of a Mac, as a phone may start it.
public struct AgentHarnessChoice: Identifiable, Hashable, Sendable {
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

    public init(id: String, name: String, family: String, isDefault: Bool = false, unavailableReason: String? = nil,
                models: [AgentModelChoice] = [], defaultModel: String? = nil, askingModes: [String] = []) {
        self.id = id
        self.name = name
        self.family = family
        self.isDefault = isDefault
        self.unavailableReason = unavailableReason
        self.models = models
        self.defaultModel = defaultModel
        self.askingModes = askingModes
    }

    public var canStart: Bool { unavailableReason == nil }

    /// ``defaultModel`` when this Mac's account offers it: a harness that lists its models
    /// and leaves the default out can't run it (full verify D4), so Default is not named.
    public var offeredDefaultModel: String? {
        guard let defaultModel else { return nil }
        guard !models.isEmpty else { return defaultModel }
        return models.contains { $0.id == defaultModel } ? defaultModel : nil
    }
}

/// The agents a Mac offers a phone: the Mac's catalog (`_acpmux/harnesses`, `_acpmux/models`)
/// with the remote rules applied, so the menu says what a phone can start and why not.
public struct AgentCatalog: Hashable, Sendable {
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
public struct AgentLastPicks: Hashable, Sendable {
    public struct Pick: Hashable, Sendable {
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
