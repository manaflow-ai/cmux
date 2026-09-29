/// The old app's built-in tab bar button IDs (`cmux.splitRight`, and the
/// short and legacy aliases it accepted) mapped onto catalog action IDs.
public enum BuiltInButtonActions {
    public struct Entry: Sendable, Hashable {
        /// Canonical config ID, used as the button id.
        public var configID: String
        /// Catalog action the button runs.
        public var actionID: String
        /// The glyph the old app showed, kept so configs look the same.
        public var symbol: String
    }

    /// Resolves a config identifier, or nil when it is not a built-in.
    public nonisolated static func entry(for identifier: String) -> Entry? {
        guard let canonical = aliases[identifier] else { return nil }
        return entries[canonical]
    }

    nonisolated static let entries: [String: Entry] = {
        let list: [Entry] = [
            Entry(configID: "cmux.newTerminal", actionID: "newSurface", symbol: "terminal"),
            Entry(configID: "cmux.newBrowser", actionID: "openBrowser", symbol: "globe"),
            Entry(configID: "cmux.splitRight", actionID: "splitRight", symbol: "square.split.2x1"),
            Entry(configID: "cmux.splitDown", actionID: "splitDown", symbol: "square.split.1x2"),
            Entry(configID: "cmux.newWorkspace", actionID: "newTab", symbol: "plus.square"),
            Entry(configID: "cmux.newAgentChat", actionID: "palette.newAgentChat", symbol: "message"),
            Entry(configID: "cmux.newCloudWorkspace", actionID: "newCloudWorkspace", symbol: "cloud.fill"),
            Entry(configID: "cmux.newCloudMachine", actionID: "newCloudMachine", symbol: "cloud"),
            Entry(configID: "cmux.mobileconnect", actionID: "palette.mobileConnect", symbol: "iphone"),
        ]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.configID, $0) })
    }()

    /// Every accepted spelling, as in the old config loader.
    nonisolated static let aliases: [String: String] = {
        let groups: [String: [String]] = [
            "cmux.newTerminal": ["cmux.newTerminal", "newTerminal"],
            "cmux.newBrowser": ["cmux.newBrowser", "newBrowser"],
            "cmux.splitRight": ["cmux.splitRight", "splitRight"],
            "cmux.splitDown": ["cmux.splitDown", "splitDown"],
            "cmux.newWorkspace": ["cmux.newWorkspace", "newWorkspace"],
            "cmux.newAgentChat": ["cmux.newAgentChat", "cmux.agentChat", "newAgentChat", "new-agent-chat", "agentChat"],
            "cmux.newCloudWorkspace": ["cmux.newCloudWorkspace", "newCloudWorkspace"],
            "cmux.newCloudMachine": ["cmux.newCloudMachine", "newCloudMachine"],
            "cmux.mobileconnect": ["cmux.mobileconnect", "cmux.mobileConnect", "mobileConnect", "mobileconnect",
                                   "cmux.connectPhone", "connectPhone"],
        ]
        var result: [String: String] = [:]
        for (canonical, spellings) in groups {
            for spelling in spellings { result[spelling] = canonical }
        }
        return result
    }()

    /// Old built-ins cmux-next has no action for yet (reported, not shown).
    nonisolated static let unsupported: Set<String> = [
        "cmux.cloudvm", "cmux.cloudVM", "cloudVM", "cloudvm", "cmux.newCloudVM", "cmux.startCloudVM",
        "cmux.newSimulator", "newSimulator", "new-simulator", "simulator",
    ]
}
