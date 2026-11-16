import AppKit
import CmuxNextAgentPane
import CmuxNextTabs

/// What the quit writes of the agent chats for the next launch (their composers and page images), never an
/// incognito window's (leo-workspace design/spaces.md "Incognito": nothing of it is kept; spaces-incognito-audit
/// leak 6). Each chat is read on its own machine: a tab id two machines share names two chats (#36767).
@MainActor enum AgentQuitFiles {
    /// The incognito tabs among the chats' views and held composers, taken before the quit's window step closes
    /// the incognito workspaces: after that a removed tab no longer reads as incognito while its view stays shown.
    static func incognitoTabs(_ tabs: AgentTabStore, isIncognito: (AgentTabKey) -> Bool) -> Set<AgentTabKey> {
        Set(tabs.views.keys.map { tabs.resolvedKey($0) } + tabs.wakeStates.keys).filter(isIncognito)
    }

    /// True when chat `key` sits in an incognito window on its own machine; a key with no machine is the first machine's.
    static func isIncognito(_ key: AgentTabKey, in services: AppServices) -> Bool {
        guard !key.machine.isEmpty else { return services.cache.browserTabs.isIncognitoTab(key.key) }
        return services.locateTab(key.key, onMachine: key.machine).flatMap { services.workspaceID(of: $0.1) }.map(services.windows.isIncognito(workspace:)) ?? false
    }

    /// True when `key` is in `incognito`. A relaunch key with no machine names an id only one machine has, on any machine.
    static func contains(_ incognito: Set<AgentTabKey>, _ key: AgentTabKey) -> Bool {
        incognito.contains(key) || key.machine.isEmpty && incognito.contains { $0.key == key.key }
    }

    /// Every chat's composer (its chips' files and shell command included) but an incognito one's.
    static func composers(_ tabs: AgentTabStore, isIncognito: (AgentTabKey) -> Bool) async -> [String: AgentPaneWakeState] {
        await tabs.relaunchWakeStates().filter { !isIncognito(AgentTabKey(relaunchStorageKey: $0.key)) }
    }

    /// The shown chats' page images but an incognito one's.
    static func images(_ tabs: AgentTabStore, isIncognito: (AgentTabKey) -> Bool) async -> [String: NSImage] {
        await tabs.shownPageImages().reduce(into: [:]) { if !isIncognito(AgentTabKey(machine: $1.machine, key: $1.key)) { $0[tabs.launchImages.slot($1.key, machine: $1.machine)] = $1.image } }
    }
}
