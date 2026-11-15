import Foundation

/// What the native New Tab page starts and opens besides the omnibar's lists: the device's chats,
/// the folders an agent may start in and the agents (Lawrence 2026-11-13: the omnibar "create new
/// agent chats, search through all existing [...] and also launch claude code/codex/opencode in
/// certain directories"). The web page's rows (webviews newtab/launchRows.ts), by the same rules.
public nonisolated struct NativeNewTabSources: Sendable, Equatable {
    /// One agent a row may start.
    public struct Agent: Sendable, Equatable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// The agents cmux starts from a New Tab page, in the web page's order.
    public static let agents = [
        Agent(id: "claude", name: "Claude Code"), Agent(id: "codex", name: "Codex"), Agent(id: "opencode", name: "OpenCode"),
    ]

    /// The device's newest chats (the Chats feed), newest first.
    public var chats: [AgentPaneDeviceChat]
    /// This Mac's project folders, most recent first (absolute).
    public var folders: [String]
    public var agents: [Agent]
    /// The agent a typed folder alone starts (the page's last pick).
    public var defaultAgent: String?
    /// The home folder, for `~`.
    public var home: String?

    public init(chats: [AgentPaneDeviceChat] = [], folders: [String] = [], agents: [Agent] = NativeNewTabSources.agents,
                defaultAgent: String? = nil, home: String? = nil) {
        self.chats = chats
        self.folders = folders
        self.agents = agents
        self.defaultAgent = defaultAgent
        self.home = home
    }

    /// The most chat rows and start rows one text lists.
    static let maximumChats = 3
    static let maximumStarts = 4
    /// Starts listed under the lead when the text names no agent (a path, a folder's name).
    static let maximumUnnamedStarts = 2
    /// Fewer letters name no agent, and a shorter word after one is no folder.
    static let minimumWord = 3

    /// The chats whose title `query` finds: a prefix or a word's start, or for 3+ letters anywhere;
    /// newest first within a tier.
    func chatRows(_ query: String) -> [AgentPaneDeviceChat] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        let scored = chats.compactMap { chat -> (chat: AgentPaneDeviceChat, score: Int)? in
            let score = NativeNewTabRanker.score(needle, [chat.title])
            return score > 0 ? (chat, score) : nil
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.chat.updatedAt > $1.chat.updatedAt }
            .prefix(Self.maximumChats).map(\.chat)
    }

    /// The agent starts `query` asks for, and whether it named an agent by its whole name with a
    /// folder's whole name or a path (then its starts lead, above Ask).
    func startRows(_ query: String) -> (rows: [NativeNewTabStart], named: Bool) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !agents.isEmpty, let intent = intent(text) else { return ([], false) }
        let found = matches(intent.path)
        guard let best = found.first else { return ([], false) }
        var rows: [NativeNewTabStart] = []
        let start = { (agent: Agent, folder: String) in NativeNewTabStart(harness: agent.id, agent: agent.name, folder: folder) }
        if intent.named {
            for folder in found { for agent in intent.agents { rows.append(start(agent, folder)) } }
        } else if let lead = intent.agents.first {
            rows.append(start(lead, best))
            for agent in intent.agents.dropFirst() { rows.append(start(agent, best)) }
            for folder in found.dropFirst() { rows.append(start(lead, folder)) }
        }
        // A word after the agent's name leads only as a folder's whole name: "claude tests" may be a
        // one-word prompt, so its starts list under Ask.
        let word = intent.path.isEmpty || Self.isPath(intent.path) ? nil : intent.path.lowercased()
        let whole = word.map { word in found.contains { Self.name(of: $0).lowercased() == word } } ?? true
        return (Array(rows.prefix(Self.maximumStarts)), intent.named && whole)
    }

    private struct Intent {
        var agents: [Agent]
        var path: String
        var named: Bool
    }

    /// "codex ~/fun/cmux", "claude code in cmux", "~/fun" or "cmux": the agents and the folder text;
    /// nil when the text is a prompt.
    private func intent(_ text: String) -> Intent? {
        let defaultFirst = agents.first { $0.id == defaultAgent }.map { first in [first] + agents.filter { $0 != first } } ?? agents
        if Self.isPath(text) {
            guard !text.contains(where: \.isWhitespace) else { return nil }
            // "/model" is a slash command being typed, not a folder under /.
            if text.hasPrefix("/"), text != "/", !text.dropFirst().contains("/") { return nil }
            return Intent(agents: defaultFirst, path: text, named: false)
        }
        let folded = text.lowercased()
        let whole = agents.first { agent in
            let name = agent.name.lowercased()
            return name.contains(" ") && (folded == name || folded.hasPrefix(name + " "))
        }
        let word = whole.map { String(text.prefix($0.name.count)) } ?? String(text.prefix { !$0.isWhitespace })
        let named: (agents: [Agent], exact: Bool) = whole.map { ([$0], true) } ?? agentsNamed(word)
        guard !named.agents.isEmpty else {
            // One word that may name a folder ("cmux"): the default agent there.
            guard let first = defaultFirst.first, defaultAgent != nil, !text.contains(where: \.isWhitespace),
                  text.count >= Self.minimumWord else { return nil }
            return Intent(agents: [first], path: text, named: false)
        }
        var rest = text.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
        if rest.lowercased() == "in" { rest = "" } else if rest.lowercased().hasPrefix("in "), rest.count > 3 {
            rest = rest.dropFirst(3).trimmingCharacters(in: .whitespaces)
        }
        // The rest is a folder (a path or one word), else the text is a prompt to the agent.
        if !rest.isEmpty, rest.contains(where: \.isWhitespace) || (!Self.isPath(rest) && rest.count < Self.minimumWord) { return nil }
        return Intent(agents: named.agents, path: rest, named: named.exact)
    }

    /// The agents `word` names: its id or its name's first word exactly (exact), else as a prefix.
    private func agentsNamed(_ word: String) -> (agents: [Agent], exact: Bool) {
        let needle = word.lowercased()
        guard needle.count >= Self.minimumWord else { return ([], false) }
        let first = { (agent: Agent) in agent.name.lowercased().split(separator: " ").first.map(String.init) ?? "" }
        let exact = agents.filter { $0.id.lowercased() == needle || first($0) == needle }
        if !exact.isEmpty { return (exact, true) }
        return (agents.filter { $0.id.lowercased().hasPrefix(needle) || first($0).hasPrefix(needle) }, false)
    }

    /// The known folders `path` finds, best first: for a path, the folders under it (itself first);
    /// for a word, those whose name starts with it, then those with a word of it; empty, the recent ones.
    private func matches(_ path: String) -> [String] {
        let known = folders.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }.filter { $0 != home }
        guard !path.isEmpty else { return Array(Self.unique(known).prefix(Self.maximumStarts)) }
        var scored: [(folder: String, score: Int)] = []
        if Self.isPath(path) {
            let full = Self.expand(path, home: home).lowercased()
            let bare = full.count > 1 && full.hasSuffix("/") ? String(full.dropLast()) : full
            for folder in known {
                let hay = folder.lowercased()
                if hay == bare { scored.append((folder, 3)) } else if hay.hasPrefix(full) { scored.append((folder, 2)) }
            }
        } else {
            let needle = path.lowercased()
            for folder in known {
                let score = NativeNewTabRanker.score(needle, [Self.name(of: folder)])
                if score >= 2 { scored.append((folder, score)) }
            }
        }
        let ranked = scored.enumerated().sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
        return Array(Self.unique(ranked.map(\.element.folder)).prefix(Self.maximumStarts))
    }

    private static func unique(_ folders: [String]) -> [String] {
        var seen = Set<String>()
        return folders.filter { seen.insert($0).inserted }
    }

    static func isPath(_ text: String) -> Bool { text == "~" || text.hasPrefix("~/") || text.hasPrefix("/") }

    static func expand(_ path: String, home: String?) -> String {
        guard let home else { return path }
        if path == "~" { return home }
        return path.hasPrefix("~/") ? home + path.dropFirst() : path
    }

    /// The name a harness's chat row shows.
    static func agentName(_ harness: String) -> String { agents.first { $0.id == harness }?.name ?? harness }

    static func name(of folder: String) -> String { folder.split(separator: "/").last.map(String.init) ?? folder }

    /// `folder` with the home folder as `~`, as the rows show it.
    static func shown(_ folder: String, home: String?) -> String {
        guard let home, !home.isEmpty else { return folder }
        if folder == home { return "~" }
        return folder.hasPrefix(home + "/") ? "~" + folder.dropFirst(home.count) : folder
    }
}
