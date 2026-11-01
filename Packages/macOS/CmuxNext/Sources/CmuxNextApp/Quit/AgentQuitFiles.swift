import AppKit
import CmuxNextAgentPane

/// What the quit writes of the agent chats for the next launch (their composers and page images), never an
/// incognito window's (leo-workspace design/spaces.md "Incognito": nothing of it is kept; spaces-incognito-audit
/// leak 6). `isIncognito` takes a tab key, as `TabContentCache.browserTabs.isIncognitoTab` does.
@MainActor enum AgentQuitFiles {
    /// Every chat's composer (its chips' files and shell command included) but an incognito one's.
    static func composers(_ tabs: AgentTabStore, isIncognito: (String) -> Bool) async -> [String: AgentPaneWakeState] {
        await tabs.relaunchWakeStates().filter { !isIncognito($0.key) }
    }

    /// The shown chats' page images but an incognito one's.
    static func images(_ tabs: AgentTabStore, isIncognito: (String) -> Bool) async -> [String: NSImage] {
        await tabs.shownPageImages().filter { !isIncognito(tabs.resolve($0.key)) }
    }
}
